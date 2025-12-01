# 2025-12-01 - CI/CD Hostname Fix

## Description

Fixed GitHub Actions workflow `check.yml` that was checking old hostnames causing email spam.

## What Was Done

1. Updated `.github/workflows/check.yml` host matrix from:

   ```yaml
   - miniserver24 # ❌ OLD
   - hsb0
   - hsb8
   - mba-gaming-pc # ❌ OLD
   ```

   To:

   ```yaml
   - hsb0
   - hsb1
   - hsb8
   - gpc0
   - csb0
   - csb1
   ```

2. Disabled broken `format-check.yml` workflow (uses non-existent `prek` command)

## Test Results

- Manual test: [x] Pass - CI runs with correct hosts
- Automated test: [x] Pass - No more failure emails
- Date verified: 2025-12-01
