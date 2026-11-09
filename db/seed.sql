-- =========================================================
-- DentAI demo data. Run AFTER schema.sql.
-- =========================================================

-- Clinic
INSERT INTO clinics (name, phone) VALUES ('BrightSmile Clinic', '+9611234567');

-- Doctors
INSERT INTO doctors (clinic_id, name_en, name_ar, specialty)
SELECT id, 'Dr. Rami Khalil', 'د. رامي خليل', 'Orthodontics' FROM clinics WHERE name = 'BrightSmile Clinic'
UNION ALL
SELECT id, 'Dr. Nour Haddad', 'د. نور حداد', 'General Dentistry' FROM clinics WHERE name = 'BrightSmile Clinic';

-- Dr. Rami: Mon-Fri, 09:00-13:00 and 14:00-18:00 (lunch break)
INSERT INTO working_hours (doctor_id, weekday, start_time, end_time)
SELECT d.id, day, b.start_time, b.end_time
FROM doctors d
CROSS JOIN generate_series(1, 5) AS day
CROSS JOIN (VALUES ('09:00'::time, '13:00'::time),
                   ('14:00'::time, '18:00'::time)) AS b(start_time, end_time)
WHERE d.name_en = 'Dr. Rami Khalil';

-- Dr. Nour: Mon, Wed, Sat, 10:00-16:00
INSERT INTO working_hours (doctor_id, weekday, start_time, end_time)
SELECT d.id, day, '10:00', '16:00'
FROM doctors d
CROSS JOIN unnest(ARRAY[1, 3, 6]) AS day
WHERE d.name_en = 'Dr. Nour Haddad';

-- Dr. Nour off on 22 November (Independence Day)
INSERT INTO time_off (doctor_id, period, reason)
SELECT id, tstzrange('2026-11-22 00:00+02', '2026-11-23 00:00+02'), 'Public holiday'
FROM doctors WHERE name_en = 'Dr. Nour Haddad';

-- Appointment types
INSERT INTO appointment_types (clinic_id, name_en, name_ar, duration_min, buffer_min)
SELECT c.id, t.name_en, t.name_ar, t.duration_min, t.buffer_min
FROM clinics c
CROSS JOIN (VALUES
  ('Checkup',    'فحص',          30, 0),
  ('Cleaning',   'تنظيف',        45, 5),
  ('Filling',    'حشوة',         60, 10),
  ('Root canal', 'سحب عصب',      90, 10)
) AS t(name_en, name_ar, duration_min, buffer_min)
WHERE c.name = 'BrightSmile Clinic';

-- Patient
INSERT INTO patients (clinic_id, phone_e164, full_name)
SELECT id, '+96170123456', 'Lina Saab' FROM clinics WHERE name = 'BrightSmile Clinic';

-- One booked appointment: Lina, checkup with Dr. Rami, Mon 16 Nov 10:00-10:30
INSERT INTO appointments (clinic_id, patient_id, doctor_id, type_id, during, source)
SELECT c.id, p.id, d.id, t.id,
       tstzrange('2026-11-16 10:00+02', '2026-11-16 10:30+02'),
       'phone'
FROM clinics c
JOIN patients p          ON p.clinic_id = c.id AND p.phone_e164 = '+96170123456'
JOIN doctors d           ON d.clinic_id = c.id AND d.name_en = 'Dr. Rami Khalil'
JOIN appointment_types t ON t.clinic_id = c.id AND t.name_en = 'Checkup'
WHERE c.name = 'BrightSmile Clinic';

-- FAQ entries (embeddings are added later by the app)
INSERT INTO faq_entries (clinic_id, question, answer)
SELECT id, q.question, q.answer
FROM clinics
CROSS JOIN (VALUES
  ('What are your opening hours?', 'Monday to Friday 9:00 to 18:00, and Saturday 10:00 to 16:00.'),
  ('Where is the clinic?',         'Hamra Street, Beirut, above the pharmacy.'),
  ('How much is a checkup?',       'A checkup costs 30 USD.')
) AS q(question, answer)
WHERE name = 'BrightSmile Clinic';
