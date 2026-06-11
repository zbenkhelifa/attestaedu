# AttestaEdu — Intégration Blockchain Polygon

## Architecture

```
Dashboard enseignant
      ↓ (valide un badge)
Supabase (stocke le badge)
      ↓ (déclenche automatiquement)
Edge Function anchor-badge
      ↓ (signe + envoie)
Smart Contract Polygon
      ↓ (hash ancré on-chain)
Supabase (mis à jour avec tx_hash)
      ↓
Page /v/[id] affiche "Ancré ✓ + lien Polygonscan"
```

---

## Étape 1 — Déployer le smart contract

### Prérequis
```bash
npm install -g hardhat
npm install ethers @nomicfoundation/hardhat-toolbox
```

### hardhat.config.js
```javascript
module.exports = {
  solidity: "0.8.20",
  networks: {
    polygon: {
      url: "https://polygon-rpc.com",
      accounts: [process.env.WALLET_PRIVATE_KEY],
    },
    // Pour tester sans frais :
    mumbai: {
      url: "https://rpc-mumbai.maticvigil.com",
      accounts: [process.env.WALLET_PRIVATE_KEY],
    }
  }
};
```

### Script de déploiement (scripts/deploy.js)
```javascript
const { ethers } = require("hardhat");

async function main() {
  const AttestaEdu = await ethers.getContractFactory("AttestaEduBadges");
  const contract = await AttestaEdu.deploy();
  await contract.waitForDeployment();
  console.log("Contrat déployé :", await contract.getAddress());
}

main().catch(console.error);
```

### Déploiement
```bash
# D'abord sur Mumbai (testnet, gratuit) pour valider
npx hardhat run scripts/deploy.js --network mumbai

# Puis sur Polygon mainnet
npx hardhat run scripts/deploy.js --network polygon
```

Coût unique de déploiement : ~0.05$ en MATIC.
Recharger le wallet AttestaEdu avec ~5$ de MATIC suffit pour 5 000+ badges.

---

## Étape 2 — Configurer les variables Supabase

Dans le dashboard Supabase → Settings → Edge Functions → Secrets :

```
POLYGON_RPC_URL      = https://polygon-rpc.com
WALLET_PRIVATE_KEY   = 0x... (clé privée du wallet AttestaEdu)
CONTRACT_ADDRESS     = 0x... (adresse après déploiement)
```

⚠️ La WALLET_PRIVATE_KEY ne doit JAMAIS être exposée côté client.

---

## Étape 3 — Déployer l'Edge Function

```bash
supabase functions deploy anchor-badge
```

---

## Étape 4 — Appeler depuis le dashboard enseignant

```javascript
// Après validation d'un badge par l'enseignant :
async function anchorBadge(badgePublicId) {
  const { data: { session } } = await supabase.auth.getSession();

  const response = await fetch(
    `${SUPABASE_URL}/functions/v1/anchor-badge`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${session.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ badge_id: badgePublicId }),
    }
  );

  const result = await response.json();

  if (result.success) {
    console.log("Ancré ✓", result.polygonscan);
    // Mettre à jour l'UI avec le lien Polygonscan
  }
}
```

---

## Étape 5 — Exécuter la migration SQL

Dans Supabase SQL Editor, exécuter `migration-blockchain.sql`.

---

## Coûts estimés

| Volume badges/mois | Frais Polygon | Supabase |
|---|---|---|
| 100 | ~0.10$ | Gratuit |
| 1 000 | ~1$ | Gratuit |
| 10 000 | ~10$ | ~25$/mois |
| 100 000 | ~100$ | ~100$/mois |

---

## Vérification publique sans AttestaEdu

N'importe qui peut vérifier un badge directement sur Polygon, sans passer par AttestaEdu :

```javascript
// Lecture directe du contrat (gratuite, sans wallet)
const provider = new ethers.JsonRpcProvider("https://polygon-rpc.com");
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, provider);

const [contentHash, issuedAt, revoked] = await contract.getBadge("ATT-2026-0012");
console.log({ contentHash, issuedAt: new Date(issuedAt * 1000), revoked });
```

C'est ça la vraie décentralisation — AttestaEdu peut disparaître, les badges restent vérifiables.
