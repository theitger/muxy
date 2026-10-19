// The phone's language, like the Mac's L10n.swift: strings are written in
// English at the call site (`t('New Session')`) and looked up in the German
// table when the phone is set to German.

export const german = typeof navigator !== 'undefined' && navigator.language.toLowerCase().startsWith('de')

/** Localized text for an English source string; `%s`/`%d` are filled from `args` in order. */
export function t(english: string, ...args: (string | number)[]) {
  const template = german ? (de[english] ?? english) : english
  let i = 0
  return args.length ? template.replace(/%[sd]/g, () => String(args[i++])) : template
}

export const de: Record<string, string> = {
  // Pairing and connection
  'Pair with Muxy': 'Mit Muxy koppeln',
  'On the Mac, open Muxy, Settings (⌘,), Phone, and scan the QR code with the camera. Then in Safari: Share, Add to Home Screen. Muxy then starts like an app.':
    'Öffne auf dem Mac Muxy, Einstellungen (⌘,), Handy, und scanne den QR-Code mit der Kamera. Danach in Safari: Teilen, Zum Home-Bildschirm. Dann startet Muxy wie eine App.',
  'Pairing expired': 'Kopplung abgelaufen',
  'Muxy has a new key. Scan the QR code in Settings under Phone again.': 'Muxy hat einen neuen Schlüssel. Scanne den QR-Code in den Einstellungen unter Handy noch einmal.',
  'Muxy unreachable': 'Muxy nicht erreichbar',
  'Is the Mac awake and Muxy open, with phone access on? Muxy keeps trying.': 'Ist der Mac wach und Muxy offen, mit eingeschaltetem Handy-Zugang? Muxy versucht es weiter.',
  'Connecting …': 'Verbinde …',
  'Remove pairing': 'Kopplung entfernen',
  Reconnecting: 'Verbinde neu',
  "Couldn't start: %s": 'Konnte nicht starten: %s',
  "Couldn't start the session": 'Konnte die Session nicht starten',

  // Home
  'New Session': 'Neue Session',
  'No open sessions': 'Keine offenen Sessions',
  'Start one on the Mac, with an agent and a task.': 'Starte eine auf dem Mac, mit einem Agent und einer Aufgabe.',
  'Waiting on you': 'Wartet auf dich',
  Running: 'Läuft',
  'Mac unreachable, still trying': 'Mac nicht erreichbar, versuche es weiter',
  '1 waiting on you': '1 wartet auf dich',
  '%d waiting on you': '%d warten auf dich',
  '1 running': '1 läuft',
  '%d running': '%d laufen',
  'All quiet': 'Alles ruhig',
  'Take a look and continue': 'Ansehen und weitermachen',
  Reply: 'Antworten',
  'Take a look': 'Ansehen',

  // Status
  '%s is waiting for your answer': '%s wartet auf deine Antwort',
  '%s hit an error': '%s ist an einem Fehler hängen geblieben',
  '%s is working': '%s arbeitet',
  '%s is done': '%s ist fertig',
  '%s is ready': '%s ist bereit',
  'New output': 'Neue Ausgabe',
  'just now': 'gerade',
  '%d min ago': 'vor %d Min.',
  '%dh ago': 'vor %d Std.',
  '%dd ago': 'vor %d T.',

  // PR checks
  'No checks': 'Keine Checks',
  'Checks running': 'Checks laufen',
  'Checks failed, being fixed': 'Checks rot, wird gefixt',
  'Checks failed': 'Checks fehlgeschlagen',
  'Merge conflicts': 'Merge-Konflikte',
  Draft: 'Entwurf',
  'Checks passed, merge blocked': 'Checks grün, Merge blockiert',
  'Ready to merge': 'Bereit zum Mergen',
  Merged: 'Gemergt',
  'Closed without merging': 'Geschlossen, nicht gemergt',

  // Session
  'Back to sessions': 'Zurück zu den Sessions',
  'Show terminal': 'Terminal zeigen',
  'Show chat': 'Chat zeigen',
  View: 'Ansicht',
  Done: 'Fertig',
  "Message for when it's done": 'Nachricht für danach',
  'Or write what to do instead': 'Oder schreib, was stattdessen',
  '“continue” restarts the turn': '„weiter“ startet die Runde neu',
  'Reply to %s': 'Antwort an %s',
  'Wrap lines': 'Zeilen umbrechen',
  'Long lines fit the screen.': 'Lange Zeilen passen auf den Bildschirm.',
  'Full history': 'Ganzer Verlauf',
  'Also loads what scrolled off the top.': 'Lädt auch, was oben aus dem Bild gelaufen ist.',
  'Pinch with two fingers to change the text size.': 'Mit zwei Fingern ziehen ändert die Schriftgröße.',

  // Chat
  'The conversation appears once %s does something in this session. Until then the terminal shows everything.':
    'Der Verlauf erscheint, sobald %s in dieser Session etwas tut. Bis dahin zeigt das Terminal alles.',
  'Nothing in this conversation yet.': 'Noch nichts in diesem Gespräch.',
  '%s needs your decision': '%s braucht deine Entscheidung',
  'The question is in the terminal.': 'Die Frage steht im Terminal.',
  'The turn died on an error': 'Die Runde ist an einem Fehler gestorben',
  'The details are in the terminal. Write “continue” and %s tries again.': 'Die Details stehen im Terminal. Schreib „weiter“, dann versucht %s es neu.',
  'Jump to the end': 'Zum Ende',
  Command: 'Befehl',
  Read: 'Gelesen',
  Edited: 'Geändert',
  Wrote: 'Geschrieben',
  Searched: 'Gesucht',
  Fetched: 'Abgerufen',
  Subtask: 'Teilaufgabe',
  '1 step': '1 Schritt',
  '%d steps': '%d Schritte',
  '%d edited': '%d geändert',
  '1 command': '1 Befehl',
  '%d commands': '%d Befehle',
  '%d failed': '%d fehlgeschlagen',

  // Composer
  Yes: 'Ja',
  No: 'Nein',
  Up: 'Hoch',
  Down: 'Runter',
  Left: 'Links',
  Right: 'Rechts',
  'Letter for ctrl': 'Buchstabe für ctrl',
  Stop: 'Stoppen',
  Send: 'Senden',

  // New session
  Start: 'Starten',
  Cancel: 'Abbrechen',
  Task: 'Aufgabe',
  'What should happen? For example: Fix the login bug and write a test for it.': 'Was soll passieren? Zum Beispiel: Behebe den Fehler beim Login und schreib einen Test dazu.',
  Search: 'Suchen',
  'Nothing found': 'Nichts gefunden',
  'Own worktree': 'Eigener Worktree',
  'Works on a new branch, apart from everything else.': 'Arbeitet auf einem neuen Branch, getrennt von allem anderen.',
  'Works right in the repository, on the current branch.': 'Arbeitet direkt im Repository, auf dem aktuellen Branch.',

  // Demo
  new: 'neu',
  'new worktree': 'neuer Worktree',
}
