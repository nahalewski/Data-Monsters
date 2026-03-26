# Make.com Blueprint Templates

These files are starter blueprints for the Lead Management System scenarios from your shared plan.

## Files

- `01-lead-intake-hub.blueprint.json`
- `02-missed-call-recovery.blueprint.json`
- `03-claim-handler.blueprint.json`
- `04-unclaimed-lead-escalation.blueprint.json`
- `05-crew-job-update-handler.blueprint.json`
- `06-customer-confirmation-handler.blueprint.json`
- `07-estimate-mhelpdesk-sync.blueprint.json`
- `08-invoice-payment-closure.blueprint.json`
- `09-daily-ops-summary.blueprint.json`

## Before importing

Replace placeholder IDs/values in each JSON:

- `SPREADSHEET_ID`
- `LEADS_SHEET`
- `USERS_SHEET`
- `AUDIT_LOG_SHEET`
- `DATA_STORE_ID`
- phone targets under `settings.*` mappings

## Notes

- Sequential processing is enabled in the scenarios where command/order integrity matters (`03` and `06`).
- Schedules match the suggested design: every 5 minutes for escalation, daily 7:30 AM for the summary.
- Module names map directly to the scenario steps so you can remap each module in Make UI quickly.
