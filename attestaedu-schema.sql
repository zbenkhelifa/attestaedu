-- ============================================================
--  AttestaEdu — Schéma Supabase MVP
--  Ordre : extensions → tables → indexes → RLS → fonctions → seed
-- ============================================================

-- ── EXTENSIONS ──────────────────────────────────────────────
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";
create extension if not exists "unaccent";


-- ============================================================
--  1. ÉTABLISSEMENTS
--  Vérifiés automatiquement par domaine email académique
-- ============================================================
create table establishments (
  id            uuid primary key default uuid_generate_v4(),
  nom           text not null,
  ville         text,
  code_uai      text unique,          -- identifiant Éducation Nationale
  academie      text,                 -- ex: "Versailles"
  email_domain  text not null,        -- ex: "monlycee.net", "ac-versailles.fr"
  public_key    text,                 -- clé publique blockchain (V2)
  verified      boolean default false,
  created_at    timestamptz default now()
);

comment on column establishments.code_uai is
  'Numéro UAI officiel — permet vérification via API Ministère en V2';
comment on column establishments.public_key is
  'Clé publique Ethereum de l'établissement — utilisée pour signature on-chain en V2';


-- ============================================================
--  2. ENSEIGNANTS
--  Auth via Supabase Auth (email académique obligatoire)
-- ============================================================
create table teachers (
  id                uuid primary key default uuid_generate_v4(),
  user_id           uuid references auth.users(id) on delete cascade,
  nom               text not null,
  prenom            text not null,
  email             text not null unique,
  establishment_id  uuid references establishments(id) on delete restrict,
  matiere           text,             -- ex: "STI2D SIN"
  verified_at       timestamptz,      -- null = en attente de vérification
  created_at        timestamptz default now()
);

comment on column teachers.verified_at is
  'Renseigné automatiquement si email correspond au domaine de l'établissement';


-- ============================================================
--  3. ÉLÈVES
--  Créés par l'enseignant, pas de compte auth requis au MVP
-- ============================================================
create table students (
  id                uuid primary key default uuid_generate_v4(),
  nom               text not null,
  prenom            text not null,
  classe            text,             -- ex: "Terminale STI2D SIN"
  annee_scolaire    text,             -- ex: "2025-2026"
  establishment_id  uuid references establishments(id) on delete restrict,
  slug              text unique,      -- ex: "yasmine-benali" pour /profil/yasmine-benali
  email             text,             -- optionnel au MVP
  created_at        timestamptz default now()
);

comment on column students.slug is
  'URL publique du profil — généré automatiquement depuis prénom+nom';


-- ============================================================
--  4. COMPÉTENCES (référentiel)
--  Catalogue partagé, enrichi par les enseignants
-- ============================================================
create table competences (
  id               uuid primary key default uuid_generate_v4(),
  nom              text not null,
  domaine          text,              -- ex: "Programmation", "Réseaux", "Systèmes"
  referentiel      text,              -- ex: "STI2D SIN BO 2024", "RNCP"
  emoji            text,              -- ex: "🐍"
  establishment_id uuid references establishments(id), -- null = compétence globale
  created_by       uuid references teachers(id),
  created_at       timestamptz default now()
);


-- ============================================================
--  5. BADGES (le cœur du produit)
-- ============================================================
create type niveau_maitrise as enum ('acquis', 'maitrise', 'expert');

create table badges (
  id               uuid primary key default uuid_generate_v4(),

  -- Relations
  student_id       uuid not null references students(id) on delete restrict,
  teacher_id       uuid not null references teachers(id) on delete restrict,
  competence_id    uuid not null references competences(id) on delete restrict,

  -- Contenu
  niveau           niveau_maitrise not null default 'acquis',
  contexte         text,             -- ex: "Projet fil rouge S2"
  public_id        text unique not null, -- ex: "ATT-2026-0012" (lisible humain)

  -- Blockchain (V2 — null au MVP)
  tx_hash          text,             -- hash transaction Polygon
  block_number     bigint,
  anchored_at      timestamptz,

  -- Révocation
  revoked_at       timestamptz,      -- null = badge actif
  revoked_by       uuid references teachers(id),
  revoke_reason    text,

  -- Timestamps
  issued_at        timestamptz default now(),
  created_at       timestamptz default now()
);

comment on column badges.public_id is
  'Identifiant lisible humain — utilisé dans les URLs /v/att-2026-0012';
comment on column badges.tx_hash is
  'Hash blockchain Polygon — null au MVP, renseigné en V2';


-- ============================================================
--  6. INDEX
-- ============================================================
create index on badges (student_id);
create index on badges (teacher_id);
create index on badges (public_id);
create index on badges (revoked_at) where revoked_at is null;
create index on students (slug);
create index on teachers (email);
create index on establishments (email_domain);


-- ============================================================
--  7. FONCTION — Génération automatique du public_id
-- ============================================================
create sequence badge_seq start 1;

create or replace function generate_public_id()
returns trigger as $$
declare
  annee text := to_char(now(), 'YYYY');
  seq   text := lpad(nextval('badge_seq')::text, 4, '0');
begin
  new.public_id := 'ATT-' || annee || '-' || seq;
  return new;
end;
$$ language plpgsql;

create trigger set_public_id
  before insert on badges
  for each row
  when (new.public_id is null)
  execute function generate_public_id();


-- ============================================================
--  8. FONCTION — Génération automatique du slug élève
-- ============================================================
create or replace function generate_student_slug()
returns trigger as $$
declare
  base_slug text;
  final_slug text;
  counter   int := 0;
begin
  -- "Yasmine Benali" → "yasmine-benali"
  base_slug := lower(
    regexp_replace(
      unaccent(new.prenom || '-' || new.nom),
      '[^a-z0-9-]', '-', 'g'
    )
  );
  final_slug := base_slug;

  -- Évite les doublons
  while exists (select 1 from students where slug = final_slug) loop
    counter := counter + 1;
    final_slug := base_slug || '-' || counter;
  end loop;

  new.slug := final_slug;
  return new;
end;
$$ language plpgsql;

create trigger set_student_slug
  before insert on students
  for each row
  when (new.slug is null)
  execute function generate_student_slug();


-- ============================================================
--  9. FONCTION — Vérification automatique enseignant
--  Si l'email correspond au domaine de l'établissement → vérifié
-- ============================================================
create or replace function auto_verify_teacher()
returns trigger as $$
declare
  domain text;
  estab_domain text;
begin
  -- Extraire le domaine de l'email
  domain := split_part(new.email, '@', 2);

  -- Chercher l'établissement correspondant
  select email_domain into estab_domain
  from establishments
  where id = new.establishment_id;

  if domain = estab_domain then
    new.verified_at := now();
  end if;

  return new;
end;
$$ language plpgsql;

create trigger verify_teacher_on_insert
  before insert on teachers
  for each row
  execute function auto_verify_teacher();


-- ============================================================
--  10. ROW LEVEL SECURITY
-- ============================================================
alter table establishments enable row level security;
alter table teachers        enable row level security;
alter table students        enable row level security;
alter table competences     enable row level security;
alter table badges          enable row level security;

-- Établissements : lecture publique
create policy "establishments_public_read"
  on establishments for select
  using (true);

-- Enseignants : lecture par membres du même établissement
create policy "teachers_read_same_establishment"
  on teachers for select
  using (
    establishment_id in (
      select establishment_id from teachers
      where user_id = auth.uid()
    )
  );

-- Enseignants : modifier uniquement son propre profil
create policy "teachers_update_own"
  on teachers for update
  using (user_id = auth.uid());

-- Élèves : lecture publique (profil public)
create policy "students_public_read"
  on students for select
  using (true);

-- Élèves : création uniquement par enseignant vérifié du même établissement
create policy "students_insert_by_verified_teacher"
  on students for insert
  with check (
    establishment_id in (
      select establishment_id from teachers
      where user_id = auth.uid()
      and verified_at is not null
    )
  );

-- Compétences : lecture publique
create policy "competences_public_read"
  on competences for select
  using (true);

-- Compétences : création par enseignant vérifié
create policy "competences_insert_by_verified_teacher"
  on competences for insert
  with check (
    created_by in (
      select id from teachers
      where user_id = auth.uid()
      and verified_at is not null
    )
  );

-- Badges : lecture publique (pour vérification /v/[id])
create policy "badges_public_read"
  on badges for select
  using (true);

-- Badges : délivrance uniquement par enseignant vérifié
--          et seulement aux élèves de son établissement
create policy "badges_insert_by_verified_teacher"
  on badges for insert
  with check (
    teacher_id in (
      select id from teachers
      where user_id = auth.uid()
      and verified_at is not null
    )
    and
    student_id in (
      select s.id from students s
      join teachers t on t.establishment_id = s.establishment_id
      where t.user_id = auth.uid()
    )
  );

-- Badges : révocation uniquement par l'enseignant qui a délivré
create policy "badges_revoke_by_issuer"
  on badges for update
  using (
    teacher_id in (
      select id from teachers where user_id = auth.uid()
    )
  )
  with check (
    revoked_at is not null -- on ne peut que révoquer, pas modifier le contenu
  );


-- ============================================================
--  11. VUE — Badge public (pour /v/[id])
--  Agrège toutes les infos nécessaires à la vérification
-- ============================================================
create or replace view badge_verification as
select
  b.public_id,
  b.niveau,
  b.contexte,
  b.issued_at,
  b.revoked_at,
  b.tx_hash,

  -- Élève
  s.prenom || ' ' || s.nom   as student_name,
  s.slug                      as student_slug,
  s.classe,

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
  e.code_uai

from badges b
join students      s on s.id = b.student_id
join competences   c on c.id = b.competence_id
join teachers      t on t.id = b.teacher_id
join establishments e on e.id = t.establishment_id;


-- ============================================================
--  12. SEED — Données de démonstration
-- ============================================================
insert into establishments (nom, ville, code_uai, academie, email_domain, verified)
values
  ('Lycée Jean Moulin', 'Morangis', '0911234A', 'Versailles', 'monlycee.net', true),
  ('Lycée Marie Curie', 'Versailles', '0780456B', 'Versailles', 'ac-versailles.fr', true);

-- Note : les teachers sont créés via Supabase Auth
-- Exécuter après création du compte auth :
--
-- insert into teachers (user_id, nom, prenom, email, establishment_id, matiere)
-- values (
--   '<uuid-from-auth>',
--   'Benkhelifa', 'Zahire',
--   'z.benkhelifa@monlycee.net',
--   (select id from establishments where code_uai = '0911234A'),
--   'STI2D SIN'
-- );

insert into competences (nom, domaine, referentiel, emoji)
values
  ('Python Niveau 1',         'Programmation', 'STI2D SIN BO 2024', '🐍'),
  ('Python Niveau 2',         'Programmation', 'STI2D SIN BO 2024', '🐍'),
  ('Arduino — Bases',         'Programmation', 'STI2D SIN BO 2024', '⚡'),
  ('Arduino — Capteurs',      'Programmation', 'STI2D SIN BO 2024', '⚡'),
  ('Réseau TCP/IP',           'Réseaux',       'STI2D SIN BO 2024', '🌐'),
  ('Protocoles HTTP/HTTPS',   'Réseaux',       'STI2D SIN BO 2024', '🔒'),
  ('Configuration routeur',   'Réseaux',       'STI2D SIN BO 2024', '📡'),
  ('Linux — Commandes base',  'Systèmes',      'STI2D SIN BO 2024', '🐧'),
  ('Linux — Scripts shell',   'Systèmes',      'STI2D SIN BO 2024', '🐧'),
  ('Bases de données SQL',    'Systèmes',      'STI2D SIN BO 2024', '🗄️');
