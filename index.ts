// ============================================================
//  AttestaEdu — Edge Function : anchor-badge
//  Supabase Edge Functions (Deno)
//
//  Déploiement :
//    supabase functions deploy anchor-badge
//
//  Variables d'environnement à configurer dans Supabase :
//    POLYGON_RPC_URL     → https://polygon-rpc.com  (ou Alchemy/Infura)
//    WALLET_PRIVATE_KEY  → clé privée du wallet AttestaEdu (jamais côté client)
//    CONTRACT_ADDRESS    → adresse du smart contract déployé
//    SUPABASE_URL        → automatique dans Edge Functions
//    SUPABASE_SERVICE_KEY→ clé service (accès admin Supabase)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { ethers } from "https://esm.sh/ethers@6.9.0";

// ABI minimal du smart contract AttestaEdu
// (voir fichier AttestaEduBadges.sol)
const CONTRACT_ABI = [
  "function issueBadge(string badgeId, bytes32 contentHash) external returns (uint256)",
  "function revokeBadge(string badgeId) external",
  "function getBadge(string badgeId) external view returns (bytes32 contentHash, uint256 issuedAt, bool revoked)",
  "event BadgeIssued(string indexed badgeId, bytes32 contentHash, uint256 timestamp)",
];

Deno.serve(async (req) => {
  // ── CORS ──
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, content-type",
      },
    });
  }

  try {
    // ── AUTH : vérifier que l'appelant est un enseignant vérifié ──
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return errorResponse("Non autorisé", 401);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_KEY")!
    );

    // Vérifier le JWT de l'enseignant
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) {
      return errorResponse("Token invalide", 401);
    }

    // Vérifier que c'est un enseignant vérifié
    const { data: teacher, error: teacherError } = await supabase
      .from("teachers")
      .select("id, establishment_id, verified_at")
      .eq("user_id", user.id)
      .single();

    if (teacherError || !teacher || !teacher.verified_at) {
      return errorResponse("Enseignant non vérifié", 403);
    }

    // ── BODY ──
    const { badge_id } = await req.json();
    if (!badge_id) {
      return errorResponse("badge_id requis", 400);
    }

    // ── Récupérer le badge depuis Supabase ──
    const { data: badge, error: badgeError } = await supabase
      .from("badge_verification")   // notre vue SQL
      .select("*")
      .eq("public_id", badge_id)
      .single();

    if (badgeError || !badge) {
      return errorResponse("Badge introuvable", 404);
    }

    if (badge.tx_hash) {
      return errorResponse("Badge déjà ancré : " + badge.tx_hash, 409);
    }

    // ── Calculer le hash du contenu (empreinte du badge) ──
    // On hash les données essentielles — toute modification invaliderait le hash
    const contentString = JSON.stringify({
      public_id:      badge.public_id,
      student_name:   badge.student_name,
      competence_nom: badge.competence_nom,
      niveau:         badge.niveau,
      teacher_name:   badge.teacher_name,
      establishment:  badge.establishment_nom,
      issued_at:      badge.issued_at,
    });

    const contentHash = ethers.keccak256(ethers.toUtf8Bytes(contentString));

    // ── Connexion Polygon ──
    const provider = new ethers.JsonRpcProvider(
      Deno.env.get("POLYGON_RPC_URL") ?? "https://polygon-rpc.com"
    );

    const wallet = new ethers.Wallet(
      Deno.env.get("WALLET_PRIVATE_KEY")!,
      provider
    );

    const contract = new ethers.Contract(
      Deno.env.get("CONTRACT_ADDRESS")!,
      CONTRACT_ABI,
      wallet
    );

    // ── Envoyer la transaction ──
    console.log(`Ancrage badge ${badge_id} sur Polygon...`);

    // Estimation dynamique des frais — évite les rejets en période de congestion
    const feeData = await provider.getFeeData();

    const tx = await contract.issueBadge(badge_id, contentHash, {
      gasLimit: 100_000,
      maxFeePerGas:         feeData.maxFeePerGas         ?? ethers.parseUnits("50", "gwei"),
      maxPriorityFeePerGas: feeData.maxPriorityFeePerGas ?? ethers.parseUnits("30", "gwei"),
    });

    console.log(`Transaction envoyée : ${tx.hash}`);

    // Attendre 2 confirmations
    const receipt = await tx.wait(2);

    console.log(`Confirmé au bloc ${receipt.blockNumber}`);

    // ── Mettre à jour Supabase avec le hash et le JSON canonique ──
    const { error: updateError } = await supabase
      .from("badges")
      .update({
        tx_hash:      tx.hash,
        block_number: receipt.blockNumber,
        anchored_at:  new Date().toISOString(),
        content_hash: contentHash,
        content_json: contentString,  // JSON exact utilisé pour le hash — nécessaire à verifyIntegrity
      })
      .eq("public_id", badge_id);

    if (updateError) {
      console.error("Erreur mise à jour Supabase:", updateError);
    }

    // ── Log d'ancrage (diagnostic) ──
    await supabase.from("anchor_logs").insert({
      badge_id,
      status:   "success",
      tx_hash:  tx.hash,
      gas_used: receipt.gasUsed ? Number(receipt.gasUsed) : null,
    });

    return new Response(
      JSON.stringify({
        success:      true,
        badge_id,
        tx_hash:      tx.hash,
        block_number: receipt.blockNumber,
        polygonscan:  `https://polygonscan.com/tx/${tx.hash}`,
        content_hash: contentHash,
      }),
      {
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );

  } catch (err) {
    console.error("Erreur anchor-badge:", err);

    // Log de l'échec pour récupération manuelle
    try {
      const { badge_id } = await req.clone().json().catch(() => ({}));
      if (badge_id) {
        const supabase = createClient(
          Deno.env.get("SUPABASE_URL")!,
          Deno.env.get("SUPABASE_SERVICE_KEY")!
        );
        await supabase.from("anchor_logs").insert({
          badge_id,
          status:    "failed",
          error_msg: err instanceof Error ? err.message : String(err),
        });
      }
    } catch { /* ne pas masquer l'erreur originale */ }

    return errorResponse(
      err instanceof Error ? err.message : "Erreur interne",
      500
    );
  }
});

function errorResponse(message: string, status: number) {
  return new Response(
    JSON.stringify({ success: false, error: message }),
    {
      status,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    }
  );
}
