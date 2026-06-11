-- ============================================================
--  AttestaEdu — Migration V2 : Blockchain
--  À exécuter dans Supabase SQL Editor après le schéma initial
-- ============================================================

-- ── 1. Colonnes blockchain déjà dans le schéma initial ──
-- tx_hash, block_number, anchored_at sont déjà dans la table badges
-- On ajoute juste content_hash pour stocker l'empreinte locale

alter table badges
  add column if not exists content_hash text;

comment on column badges.content_hash is
  'keccak256 des données du badge — doit correspondre à ce qui est ancré on-chain';

alter table badges
  add column if not exists content_json text;

comment on column badges.content_json is
  'JSON canonique utilisé pour calculer content_hash — même chaîne exacte que JSON.stringify() côté Edge Function';


-- ── 2. VUE enrichie avec statut blockchain ──
create or replace view badge_verification as
select
  b.public_id,
  b.niveau,
  b.contexte,
  b.issued_at,
  b.revoked_at,
  b.tx_hash,
  b.block_number,
  b.anchored_at,
  b.content_hash,

  -- Statut lisible
  case
    when b.revoked_at is not null then 'revoked'
    when b.tx_hash is not null    then 'anchored'
    else                               'pending'
  end as blockchain_status,

  -- Lien Polygonscan direct
  case
    when b.tx_hash is not null
    then 'https://polygonscan.com/tx/' || b.tx_hash
    else null
  end as polygonscan_url,

  -- Élève
  s.prenom || ' ' || s.nom   as student_name,
  s.slug                      as student_slug,
  s.classe,
  s.annee_scolaire,

  -- Compétence
  c.nom                       as competence_nom,
  c.domaine                   as competence_domaine,
  c.referentiel,
  c.emoji,

  -- Enseignant
  t.prenom || ' ' || t.nom   as teacher_name,

  -- Établissement
  e.nom                       as establishment_nom,
  e.ville                     as establishment_ville,
  e.academie,
  e.code_uai,
  e.public_key                as establishment_public_key

from badges b
join students       s on s.id = b.student_id
join competences    c on c.id = b.competence_id
join teachers       t on t.id = b.teacher_id
join establishments e on e.id = t.establishment_id;


-- ── 3. VUE wallet élève ──
-- Tous les badges d'un élève via son slug
-- Note : jointures inline — évite de passer par la vue badge_verification
--        qui rejoindrait les mêmes tables une seconde fois
create or replace view student_wallet as
select
  b.public_id,
  b.niveau,
  b.contexte,
  b.issued_at,
  b.revoked_at,
  b.tx_hash,
  b.block_number,
  b.anchored_at,
  b.content_hash,
  case
    when b.revoked_at is not null then 'revoked'
    when b.tx_hash    is not null then 'anchored'
    else                               'pending'
  end as blockchain_status,
  case
    when b.tx_hash is not null
    then 'https://polygonscan.com/tx/' || b.tx_hash
    else null
  end as polygonscan_url,

  s.prenom || ' ' || s.nom   as student_name,
  s.slug                      as student_slug,
  s.slug                      as wallet_slug,
  s.prenom                    as student_prenom,
  s.nom                       as student_nom,
  s.classe,
  s.annee_scolaire,

  c.nom                       as competence_nom,
  c.domaine                   as competence_domaine,
  c.referentiel,
  c.emoji,

  t.prenom || ' ' || t.nom   as teacher_name,

  e.nom                       as establishment_nom,
  e.ville                     as establishment_ville,
  e.academie,
  e.code_uai,
  e.public_key                as establishment_public_key,

  count(*) over (partition by s.id)              as total_badges,
  count(*) over (partition by s.id, c.domaine)   as badges_in_domain,
  count(*) filter (where b.tx_hash is not null)
           over (partition by s.id)              as anchored_count

from badges b
join students       s  on s.id  = b.student_id
join competences    c  on c.id  = b.competence_id
join teachers       t  on t.id  = b.teacher_id
join establishments e  on e.id  = t.establishment_id
where b.revoked_at is null;


-- ── 4. FONCTION : récupérer le JSON canonique d'un badge ──
-- Retourne la chaîne stockée lors de l'ancrage (identique à JSON.stringify() côté Edge Function)
-- Ne recompute pas via json_build_object() dont le format diffère de JS (espaces autour du ':')
create or replace function badge_content_json(badge_public_id text)
returns text as $$
  select content_json
  from badges
  where public_id = badge_public_id;
$$ language sql stable;


-- ── 5. INDEX supplémentaires pour les requêtes blockchain ──
create index if not exists badges_tx_hash_idx
  on badges (tx_hash) where tx_hash is not null;

create index if not exists badges_anchored_at_idx
  on badges (anchored_at) where anchored_at is not null;

create index if not exists badges_pending_idx
  on badges (created_at) where tx_hash is null and revoked_at is null;


-- ── 6. TABLE : log des tentatives d'ancrage ──
-- Pour diagnostiquer les échecs sans perdre de données
create table if not exists anchor_logs (
  id          uuid primary key default uuid_generate_v4(),
  badge_id    text not null,
  status      text not null,  -- 'success' | 'failed' | 'retry'
  tx_hash     text,
  error_msg   text,
  gas_used    bigint,
  created_at  timestamptz default now()
);

alter table anchor_logs enable row level security;

-- Seul le service key peut lire les logs
create policy "anchor_logs_service_only"
  on anchor_logs for all
  using (false);  -- bloqué pour tous sauf service_role
