# Beutezug

Spielautomaten-Aufbauspiel im Browser: drehen, angreifen, überfallen, Dörfer bauen, Karten sammeln, Glücksräder und Teams.

Läuft komplett als eine Datei (`index.html`) – ideal für **GitHub Pages**. Ohne Datenbank spielt man offline (Spielstand im Browser). Mit **Supabase** gibt es Konten, Cloud-Spielstand und echte Teams mit anderen Spielern.

## Spielen

Nach dem Einrichten von GitHub Pages: `https://robertpahl1987-creator.github.io/beutezug/`

## Datenbank einrichten (Supabase, kostenlos)

1. Auf [supabase.com](https://supabase.com) ein Konto und ein neues Projekt anlegen.
2. Im Projekt **SQL Editor → New query** öffnen, den kompletten Inhalt von [`supabase/schema.sql`](supabase/schema.sql) einfügen und **Run** drücken.
3. **Authentication → Sign In / Providers → Email**: „Confirm email“ ausschalten, wenn sich Spieler ohne Bestätigungsmail sofort anmelden sollen (optional).
4. **Project Settings → API**: „Project URL“ und den „anon public“-Key kopieren.
5. Entweder im Spiel oben auf den **Konto-Knopf** tippen und beides eintragen, **oder** in `index.html` fest eintragen:
   ```js
   const CLOUD_DEFAULT={url:'https://DEIN-PROJEKT.supabase.co',key:'DEIN-ANON-KEY'};
   ```
   Der anon-Key ist öffentlich gedacht; die Daten sind über Row Level Security geschützt.

## Was in der Datenbank liegt

| Tabelle | Inhalt |
|---|---|
| `profiles` | Spielername und Sterne pro Konto |
| `saves` | kompletter Spielstand (JSON) pro Spieler |
| `teams` | Teams mit Name, Flagge, Beschreibung, offen/auf Anfrage, Anführer, Team-Schloss |
| `team_members` | wer in welchem Team ist (max. 50, ein Team pro Spieler) |
| `team_join_requests` | Beitrittsanfragen für geschlossene Teams |
| `team_messages` | Team-Chat, Versuchs-Anfragen und Systemmeldungen |
| `team_help` | wer bei welcher Anfrage geholfen hat (je Spieler einmal) |

Alle Team-Aktionen (gründen, beitreten, annehmen, entfernen, verlassen, helfen, abholen, Schloss bauen) laufen über geprüfte Datenbank-Funktionen, damit niemand schummeln kann.

## Noch offen

- Angriffe und Überfälle gehen gegen computergesteuerte Nachbarn, nicht gegen echte Spieler.
- Karten werden zwischen echten Spielern noch nicht direkt verschickt.
