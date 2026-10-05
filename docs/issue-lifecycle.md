# Gutenprint Issue Lifecycle & Delivery Verification

This document describes the issue lifecycle for the Gutenprint Printer Application.

## Roles and Responsibilities

- **Maintainer**: Reviews incoming issues, clarifies scope, accepts implementation by adding `triage/accepted`, assigns contributors, and records delivery evidence once a fix is built and published.
- **Reporter**: Reports problems or suggestions, answers clarification questions when more information is requested, and tests verified image delivery to confirm the fix.

## Delivery Evidence Fields

When an accepted fix merges into `testing`, image delivery to GHCR must be proven before the issue is closed. The maintainer records delivery evidence in the issue body with the following receipt fields:

Image: ghcr.io/projectbluefin/gutenprint-printer-app@sha256:<digest>
Fix revision: <commit-sha>
Release/build: https://github.com/projectbluefin/gutenprint-printer-app/actions/runs/<run-id>
Verify: <specific steps for reporter testing and verification>

Merge alone is not delivery; the reporter verifies the published image and reports the observed outcome.
