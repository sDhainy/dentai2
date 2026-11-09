-- =========================================================
-- DentAI database schema (PostgreSQL 17)
-- Run on an empty database.
-- =========================================================

-- Extensions --------------------------------------------------
-- btree_gist: lets one constraint combine "same doctor" (=) with
--             "overlapping time" (&&) -> blocks double-booking
-- vector:     pgvector, stores AI embeddings for FAQ search
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS vector;

-- Auto-update "updated_at" on every UPDATE ----------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =========================================================
-- 1. clinics
-- =========================================================
CREATE TABLE clinics (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  timezone   TEXT NOT NULL DEFAULT 'Asia/Beirut',
  phone      TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================================================
-- 2. doctors
-- =========================================================
CREATE TABLE doctors (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id  UUID NOT NULL REFERENCES clinics(id),
  name_en    TEXT NOT NULL,
  name_ar    TEXT NOT NULL,
  specialty  TEXT,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_doctors_clinic_id ON doctors (clinic_id);

-- =========================================================
-- 3. working_hours  (weekly schedule, several blocks per day)
-- weekday: 0 = Sunday ... 6 = Saturday
-- =========================================================
CREATE TABLE working_hours (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doctor_id  UUID NOT NULL REFERENCES doctors(id),
  weekday    SMALLINT NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_time TIME NOT NULL,
  end_time   TIME NOT NULL,
  CHECK (end_time > start_time)
);
CREATE INDEX idx_working_hours_doctor_id ON working_hours (doctor_id);

-- =========================================================
-- 4. time_off  (holidays, leave)
-- =========================================================
CREATE TABLE time_off (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doctor_id  UUID NOT NULL REFERENCES doctors(id),
  period     TSTZRANGE NOT NULL CHECK (NOT isempty(period)),
  reason     TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_time_off_doctor_period ON time_off USING gist (doctor_id, period);

-- =========================================================
-- 5. appointment_types  (cleaning 45 min, root canal 90 min ...)
-- =========================================================
CREATE TABLE appointment_types (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id    UUID NOT NULL REFERENCES clinics(id),
  name_en      TEXT NOT NULL,
  name_ar      TEXT NOT NULL,
  duration_min INTEGER NOT NULL CHECK (duration_min BETWEEN 5 AND 480),
  buffer_min   INTEGER NOT NULL DEFAULT 0 CHECK (buffer_min >= 0),
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_appointment_types_clinic_id ON appointment_types (clinic_id);

-- =========================================================
-- 6. patients  (identified by phone, no password)
-- =========================================================
CREATE TABLE patients (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id      UUID NOT NULL REFERENCES clinics(id),
  phone_e164     TEXT NOT NULL CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  full_name      TEXT,
  preferred_lang TEXT NOT NULL DEFAULT 'ar' CHECK (preferred_lang IN ('ar', 'en', 'fr')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (clinic_id, phone_e164)
);

-- =========================================================
-- 7. appointments  (the core table)
-- =========================================================
CREATE TABLE appointments (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id       UUID NOT NULL REFERENCES clinics(id),
  patient_id      UUID NOT NULL REFERENCES patients(id),
  doctor_id       UUID NOT NULL REFERENCES doctors(id),
  type_id         UUID NOT NULL REFERENCES appointment_types(id),
  during          TSTZRANGE NOT NULL CHECK (NOT isempty(during)),
  status          TEXT NOT NULL DEFAULT 'booked'
                  CHECK (status IN ('booked', 'completed', 'cancelled', 'no_show')),
  source          TEXT NOT NULL
                  CHECK (source IN ('phone', 'web', 'staff', 'whatsapp')),
  notes           TEXT,
  idempotency_key TEXT UNIQUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- THE key rule: a doctor can never have two active appointments
  -- whose times overlap. Cancelled ones don't count.
  CONSTRAINT no_double_booking
    EXCLUDE USING gist (doctor_id WITH =, during WITH &&)
    WHERE (status IN ('booked', 'completed'))
);
CREATE INDEX idx_appointments_patient_id ON appointments (patient_id);
CREATE INDEX idx_appointments_clinic_start ON appointments (clinic_id, lower(during));

-- =========================================================
-- 8. slot_holds  (reserve a slot ~2 min while the caller confirms)
-- The app deletes expired holds before creating a new one.
-- =========================================================
CREATE TABLE slot_holds (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doctor_id  UUID NOT NULL REFERENCES doctors(id),
  during     TSTZRANGE NOT NULL CHECK (NOT isempty(during)),
  call_id    TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT no_overlapping_holds
    EXCLUDE USING gist (doctor_id WITH =, during WITH &&)
);

-- =========================================================
-- 9. calls  (one row per phone/browser call -> analytics)
-- =========================================================
CREATE TABLE calls (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id      UUID NOT NULL REFERENCES clinics(id),
  patient_id     UUID REFERENCES patients(id),
  twilio_sid     TEXT UNIQUE,
  channel        TEXT NOT NULL CHECK (channel IN ('phone', 'browser')),
  started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at       TIMESTAMPTZ,
  outcome        TEXT CHECK (outcome IN ('booked', 'rescheduled', 'cancelled',
                                         'answered_faq', 'handed_off', 'abandoned', 'failed')),
  cost_usd       NUMERIC(10, 4),
  latency_p50_ms INTEGER,
  transcript     JSONB,
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX idx_calls_clinic_started ON calls (clinic_id, started_at DESC);

-- =========================================================
-- 10. faq_entries  (what the AI may answer; embedding for search)
-- =========================================================
CREATE TABLE faq_entries (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id  UUID NOT NULL REFERENCES clinics(id),
  question   TEXT NOT NULL,
  answer     TEXT NOT NULL,
  embedding  vector(1536),
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_faq_embedding ON faq_entries USING hnsw (embedding vector_cosine_ops);

-- =========================================================
-- 11. staff_users  (dashboard logins)
-- =========================================================
CREATE TABLE staff_users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinic_id     UUID NOT NULL REFERENCES clinics(id),
  doctor_id     UUID REFERENCES doctors(id),
  email         TEXT NOT NULL UNIQUE,
  full_name     TEXT NOT NULL,
  role          TEXT NOT NULL CHECK (role IN ('admin', 'doctor', 'receptionist')),
  password_hash TEXT NOT NULL,
  is_active     BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =========================================================
-- 12. audit_log  (who changed what, and when)
-- =========================================================
CREATE TABLE audit_log (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  clinic_id  UUID NOT NULL REFERENCES clinics(id),
  actor_type TEXT NOT NULL CHECK (actor_type IN ('staff', 'agent', 'system')),
  actor_id   UUID,
  action     TEXT NOT NULL,
  entity     TEXT NOT NULL,
  entity_id  UUID,
  details    JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_log_clinic_created ON audit_log (clinic_id, created_at DESC);

-- =========================================================
-- updated_at triggers
-- =========================================================
CREATE TRIGGER trg_clinics_updated           BEFORE UPDATE ON clinics           FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_doctors_updated           BEFORE UPDATE ON doctors           FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_appointment_types_updated BEFORE UPDATE ON appointment_types FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_patients_updated          BEFORE UPDATE ON patients          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_appointments_updated      BEFORE UPDATE ON appointments      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_faq_entries_updated       BEFORE UPDATE ON faq_entries       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_staff_users_updated       BEFORE UPDATE ON staff_users       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
