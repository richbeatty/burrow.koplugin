# Burrow notices

Burrow is a modified, combined work distributed under the GNU Affero General Public License, version 3.

It includes and modifies code from:

- **ProjectTitle**, by Joshua Cantrell, licensed under GNU AGPL v3.
- **OPDS Plus**, by greywolf1499, licensed under GNU AGPL v3.
- **KOReader**, by the KOReader contributors, licensed under GNU AGPL v3.
- The rounded quick-settings patch originally published by qewer33, with further Burrow modifications.
- Status-bar preset-cycling behavior derived from work published in sebdelsol/KOReader.patches, with independent margin controls and further Burrow modifications.

The bundled code was reorganized and modified for Burrow on August 4, 2026. Burrow 0.1.3 moved active code, settings keys, persistent filenames, internal patches, and the embedded Store into Burrow-owned namespaces. Legacy names are retained only for migration, conflict detection, removal guidance, and attribution.

Burrow is not affiliated with or endorsed by the upstream projects or their contributors.
Burrow 0.2.1 loads its modules from inside the plugin and does not require an external bootstrap patch. This architectural change does not alter the upstream attribution or license obligations described above.
