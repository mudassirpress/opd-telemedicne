-- Migration: 001_doctor_profile_image_nullable.sql
-- Description: Ensure the profile_image column in the doctors table allows NULL values.
-- Allows doctors to remove/delete their profile pictures and fallback to default avatars.

-- PostgreSQL:
ALTER TABLE doctors ALTER COLUMN profile_image DROP NOT NULL;

-- MySQL (if using MySQL / MariaDB):
-- ALTER TABLE doctors MODIFY COLUMN profile_image VARCHAR(1024) NULL DEFAULT NULL;

-- SQLite (if using SQLite):
-- SQLite columns are nullable by default unless defined with NOT NULL.
-- In SQLite 3.35.0+, column nullability can be altered or recreated if strictly constrained.
