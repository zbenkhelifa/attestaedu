# AttestaEdu — Ce qu'il reste à faire

## 1. Supabase — Infrastructure

- [ ] Exécuter `attestaedu-schema.sql` dans le SQL Editor Supabase
- [ ] Exécuter `migration-blockchain.sql` (colonnes blockchain + vues enrichies)
- [ ] Configurer les secrets Edge Functions (Settings → Edge Functions → Secrets) :
  - `POLYGON_RPC_URL`
  - `WALLET_PRIVATE_KEY`
  - `CONTRACT_ADDRESS`
  - `SUPABASE_SERVICE_KEY`
- [ ] Déployer l'Edge Function : `supabase functions deploy anchor-badge`
- [ ] Insérer le compte enseignant après création auth (voir commentaire en bas du schéma SQL)

## 2. Smart contract — Blockchain

- [ ] Installer les dépendances Hardhat (`npm install`)
- [ ] Créer `hardhat.config.js` (voir README)
- [ ] Déployer sur **Mumbai** (testnet) pour valider
- [ ] Déployer sur **Polygon mainnet** et noter l'adresse du contrat
- [ ] Alimenter le wallet AttestaEdu en MATIC (~5$ suffisent pour 5 000+ badges)

## 3. Frontend — Brancher Supabase

Les 3 pages sont actuellement des maquettes statiques (données en dur). À connecter :

### Page `/v/[id]` — Vérification badge
- [ ] Lire l'ID depuis `window.location.pathname`
- [ ] Requête Supabase sur la vue `badge_verification` avec `public_id = id`
- [ ] Afficher le statut blockchain (`pending` / `anchored` / `revoked`)
- [ ] Afficher le lien Polygonscan si ancré
- [ ] Gérer le cas badge introuvable (404)

### Page `/profil/[slug]` — Wallet élève
- [ ] Lire le slug depuis `window.location.pathname`
- [ ] Requête Supabase sur la vue `student_wallet` avec `wallet_slug = slug`
- [ ] Afficher les badges réels avec filtre par domaine
- [ ] Corriger l'URL dans `copyLink()` (hardcodée sur `yasmine-benali`)

### Page `/admin` — Dashboard enseignant
- [ ] Implémenter l'authentification Supabase Auth (email académique)
- [ ] Rediriger vers `/` si non connecté
- [ ] Charger la liste des élèves de l'établissement
- [ ] Formulaire de création d'élève
- [ ] Formulaire de délivrance de badge (sélection élève + compétence + niveau)
- [ ] Bouton "Ancrer sur Polygon" → appel Edge Function `anchor-badge`
- [ ] Afficher le statut d'ancrage en temps réel (polling ou Supabase Realtime)

## 4. Auth enseignant

- [ ] Activer Supabase Auth avec provider email
- [ ] Configurer le domaine autorisé (email académique uniquement)
- [ ] Page de connexion / inscription
- [ ] Vérification automatique par domaine email (trigger SQL déjà en place)

## 5. Page d'accueil

- [ ] Créer une page `/index.html` (actuellement redirige vers l'admin)
- [ ] Présenter le projet + lien vers vérification publique

## 6. Améliorations futures (V2)

- [ ] Signature par l'établissement (champ `public_key` déjà prévu dans le schéma)
- [ ] Compte élève avec accès à son wallet
- [ ] Vérification UAI via API Ministère de l'Éducation Nationale
- [ ] Export PDF des badges
- [ ] Notifications email à l'élève lors de la délivrance d'un badge
