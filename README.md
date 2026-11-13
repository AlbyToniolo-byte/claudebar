# ClaudeBar

Lo stato di Claude Code nella Touch Bar del MacBook Pro, sempre visibile nella Control Strip:

- arco arancione che gira: Claude sta lavorando
- `!` giallo che pulsa: aspetta te (permesso o domanda)
- spunta verde: ha finito
- anello grigio: nessuna sessione

Quando Claude chiede un permesso la barra si apre da sola con **Approva**, **Nega** e **Terminale** (= rispondi nel dialogo normale). Toccando il simbolo si vede la lista delle sessioni.

## Installazione

```sh
./build.sh install   # compila, copia in /Applications, avvia (e la registra all'accesso)
```

Poi in `~/.claude/settings.json`, dentro `"hooks"`, lo stesso comando per ogni evento:

```json
"UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook" }] }],
"PreToolUse":        [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook" }] }],
"PostToolUse":       [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook" }] }],
"PermissionRequest": [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook", "timeout": 600 }] }],
"Notification":      [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook" }] }],
"Stop":              [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook" }] }],
"StopFailure":       [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook" }] }],
"SessionEnd":        [{ "hooks": [{ "type": "command", "command": "/Applications/ClaudeBar.app/Contents/MacOS/ClaudeBar --hook" }] }]
```

## Come funziona

Lo stesso eseguibile fa da hook (`--hook`: legge l'evento da stdin, scrive un file in `~/Library/Application Support/ClaudeBar/` ed esce in ~20 ms) e da app (legge quei file 5 volte al secondo). Per un permesso l'hook resta in attesa fino a 2 minuti di un file di risposta scritto dai tasti della barra; se l'app è spenta, se rispondi altrove o se scade, non decide niente e resta il dialogo normale.

Usa le stesse funzioni private della Touch Bar di TouchPet (`private.h`): niente App Store.
