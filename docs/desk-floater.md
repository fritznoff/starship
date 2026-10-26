# Starship Floater (Deepgram ears + mouth)

A Mac-native always-on-top push-to-talk control for **this** Firstmate home.
It recreates the *feel* of a floating desk mic without depending on the
ChatGPT/Codex desktop app.

On Windows, where Starship runs inside WSL 2, the [Windows desk floater](desk-floater-windows.md) does the same through the same delivery scripts.

The floater is mouth and ears only, plus a dictation keyboard you drive yourself.
It does not spawn workers, merge, edit config, or act as a second Firstmate.
Exactly one fleet brain remains: the primary already running in this home.

## What you get

- Always-on-top, draggable floating control (SwiftUI): a small talk button with four smaller controls beside it, and a dropdown arrow for recent replies.
- Push-to-talk (hold or click-to-toggle), or hold Right Option anywhere. Not always-listening. No wake word.
- Out of sight until you ask for it: it starts hidden and ignores every hotkey until you press the [activation chord](#activating-the-floater).
- Speech-to-text via Deepgram (`bin/fm-deepgram-stt.sh`).
- Transcripts typed straight into the primary Firstmate chat and submitted, with a durable mailbox under the home (`state/desk-voice/inbox/`) as the fallback.
- No length limit on a message, and no recording lost unintentionally: one that cannot be transcribed or delivered is saved and tried again (see [Recordings are never lost](#recordings-are-never-lost)).
- Optional speak-back of Firstmate outcome lines through `bin/fm-speak.sh`,
  which speaks through macOS `say` when `config/speak` names a `voice` and
  through Deepgram Aura otherwise, each the fallback for the other.
- Stop, Repeat and Mute controls for that spoken voice, a voice-volume level of its own, and a list of the recent spoken replies to hear any of them again.
- A dictation mode that types what you say into whatever text box has the cursor, and sends it when that text box is the Firstmate chat.
- Quick screenshots sent to Firstmate on their own or together with a voice message (see [Screenshots](#screenshots)).

## Enablement

1. Put `DEEPGRAM_API_KEY=...` in this home's gitignored `.env` (or export it).
   Never commit the key. Scripts never log it.
2. Opt the home into desk voice-out with private `config/speak`:

   ```
   enabled = true
   ```

   Spoken replies are not yet available for teammates; skip this step.

3. Launch the floater:

   ```
   bin/fm-desk-floater.sh
   ```

   When `/Applications/Starship Floater.app` exists, the launcher opens it without compiling or signing a source copy.
   Otherwise it builds the Swift package under `desk-floater/` into `desk-floater/.build/` (gitignored) and opens the floating control.
   If any permission is missing, a setup window explains it and opens the right System Settings page (see [Permissions](#permissions)).
   The buttons work without Accessibility, the hotkeys and typing into other apps do not, and screenshots need Screen Recording.

4. Press Right Command, Right Option and Right Shift together (the default activation shortcut) to bring the floater up (see [Activating the floater](#activating-the-floater)), then hold the button (or click to toggle), speak, release.
   The transcript is typed into the primary Firstmate chat and submitted, or saved to the mailbox when that chat cannot be reached.

## Prebuilt Homebrew app

The private-Mac distribution uses the public `fritznoff/starship` fork's GitHub releases and the `fritznoff/starship` Homebrew tap (repository `fritznoff/homebrew-starship`).
After the release and tap are published:

```sh
brew install --cask fritznoff/starship/starship-floater
```

Homebrew installs `Starship Floater.app` in `/Applications` by default.
The initial cask supports Apple Silicon and macOS 14 or newer; it does not install Firstmate's scripts or their dependencies.
Keep a separate Firstmate installation available on disk.
The app is Apple Development-signed, not Developer ID-signed or notarized.
The cask deliberately clears quarantine from this app only, bypassing Gatekeeper's downloaded-app check; install it only if you trust the release publisher.
Accessibility, Microphone, Screen Recording and Terminal Automation permissions still apply.
There is no auto-update; use `brew upgrade --cask starship-floater` after a new cask version is published.

Launching with `bin/fm-desk-floater.sh` selects the installed app when present and saves the current code folder and `FM_HOME` in the per-user JSON below, so Finder, login items and Quit & Reopen keep serving the same home.
Each such launch selects that home for future environment-free launches; the file is replaced atomically and is readable only by your user.
Quit the floater before selecting a different home: macOS does not replace the environment of an already running app.
It unregisters other copies of the launched identifier and registers the installed app, without modifying or deleting source bundles.
An invalid installed bundle or failed registration stops the launch rather than falling back to a competing source copy.
`--build-only` and `--release` remain explicit build operations and never launch or register their bundles.

Finder and login items do not inherit shell exports.
To open the installed app directly before using the launcher, create `~/Library/Application Support/Firstmate/desk-floater.json` with absolute paths before opening the installed app:

```json
{
  "root": "/Users/you/starship",
  "home": "/Users/you/starship"
}
```

`root` is the Firstmate code folder containing executable `bin/fm-desk-voice.sh`; `home` is its private operational home and defaults to `root` when omitted.
For a separate operational home, set `home` to that directory instead.
Put `DEEPGRAM_API_KEY` in that home's gitignored `.env`, not in this JSON file.
The app reads this file only when it cannot locate scripts from the launch environment, its in-repository bundle location, or its current directory.
Explicit `FM_DESK_FLOATER_ROOT` and `FM_HOME` still take precedence; `FM_HOME` alone also locates scripts when it points to a code folder.
Invalid or absent configuration leaves the app with an explanatory alert instead of guessing a home.
Script subprocesses retain the inherited `PATH`, with `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin` appended so Finder launches can find Homebrew and user-installed helpers.
Restart the app after changing its configuration.

To prepare a release without launching or registering another copy, use `bin/fm-desk-floater.sh --release VERSION OUTPUT_DIR` (see its `--help` for the exact build, signing and archive contract).
Update the tap's cask version and sha256 from that command's output, publish the zip on the fork's matching `starship-floater-vVERSION` release, and publish the cask only after its asset is available.
Keep release assets immutable: a changed build gets a new version rather than replacing a zip that an installed cask already checks by hash.

## Beta install

Run `bin/fm-desk-floater.sh --beta [<source-dir>]` to install the full app as **Starship Floater Beta** beside the regular app; omit the source directory to build this copy.
It serves the same Firstmate home, with its own app settings and permission grants, and starts with **Left Control + Left Option + Left Shift** as its changeable activation shortcut.
Switch the regular floater off with its activation shortcut before activating beta: their talk, dictation and screenshot hotkeys are shared.
Grant the beta its own Microphone, Accessibility, Screen Recording and Terminal Automation permissions once, as needed; updates use the same signing identity to preserve grants.
A valid signing identity is required; an unsigned or failed build does not replace an existing beta.
Rerunning the command quits and updates only beta, never the regular app; reopen beta to change its shortcut.
The launcher's `--help` owns exact install and build locations.

## App generation

The lower-left Roman numeral identifies the app's generation: I, II, III and so on, beginning at I for this change.
The regular app reveals it only while hovering over the floater; beta always shows β immediately to its left.
Both channels reserve the same prefix space, so the numeral stays anchored in the same position.
The single source-controlled counter is `FloaterGeneration.current` in `desk-floater/Sources/DeskFloater.swift`.
Before each new regular release, increment that counter by one and commit it before building the release.
Beta displays the next generation, derived as that same counter plus one: when the regular app shows II, beta shows β III.
The release helper does not increment it automatically: rebuilding the same release or beta must not consume another generation.

## Activating the floater

The floater starts hidden, and while it is hidden none of the hotkeys below do anything.
Press the activation shortcut (Right Command + Right Option + Right Shift by default), and it appears; from then on the hotkeys work.
Press the same chord again and it disappears and the hotkeys go quiet again.
Only the selected left/right modifier keys count, and completing the chord never sends a recording or starts dictation or a screenshot, whichever key you press first.
If a capture had just begun as the first key of the chord went down, it is dropped without sending anything.
Release all selected keys before pressing the chord again.

To change the shortcut, launch the already-running floater again (open the app again or run `bin/fm-desk-floater.sh`).
Only that second launch opens the Activation Shortcut settings window; ordinary activation and the initial launch do not open it.
Pick at least two of the left/right Command, Option, Shift and Control keys, for example Right Command + Right Option.
Valid changes apply immediately and are saved for the app; incomplete selections do not replace the last valid shortcut.
A warning identifies keys shared with the existing talk, dictation and screenshot hotkeys, which are unchanged.
The floater ignores hotkeys while this window is open, so choosing keys cannot trigger a capture.
Close the window to use the new shortcut.

The same settings window has an **Animated background** switch, on by default and saved for each app channel.
Switching it off removes the optional Metal module entirely, leaving a plain plate with no background computation.
When enabled, a calm lattice fills the plate; starting talk or dictation pushes a ripple from the round button, live speech adds rate-limited ripples scaled to the microphone level, and pointer movement stirs the pool in proportion to speed.
The visible plate looks into the centre of a larger pool: waves leave the view, reflect from unseen walls and corners, return as interference, and gradually settle.
Drawing stops when calm or out of sight.
The live, saved **Damping**, **Dot size**, **Dot brightness**, and **Dot spacing** sliders control persistence and the lattice; lower damping keeps waves alive longer.
**Reset sliders** restores their defaults without switching a disabled animation back on.
Reduce Motion keeps a static lattice; Reduce Transparency removes it and makes the plate opaque.
If Metal is unavailable, the controls still work over a plain plate.

It also switches itself off after two minutes without use. Use means the chord, any hotkey, a click on the floater, and any recording, dictation, screenshot or message still being sent or waiting to be sent or retried; it never switches off under those, and the two minutes start again when they finish. Sending a message does not hide it.
Without the Accessibility permission the chord cannot be read, so the floater stays in sight (with its "!" badge, see [Permissions](#permissions)) until the permission is granted, and then hides.
The microphone is made ready when the floater appears, not at launch, so the first words after the chord are kept.

## Cancelling a capture

Press Escape while recording, transcribing, or waiting to send to discard the pending voice message, dictation and stacked screenshots together.
A ready transcript waits two seconds before it can be sent, typed, pasted or put in the delivery mailbox; the main button's tooltip and accessibility value include the countdown and Escape reminder.
Screenshots keep their existing three-second stack window after the last image finishes; that whole window is cancellable too.
Cancellation deletes the pending audio and screenshots rather than saving them for retry, ignores any transcription or screenshot result still arriving, and briefly reports “Cancelled” in the main button's tooltip and accessibility value.
Escape is only observed through the existing Accessibility key monitoring: it still reaches the focused app unchanged, and does nothing to the floater when nothing is pending.
Once delivery has begun, Escape cannot recall it or remove a message already in the mailbox.

## Controls

Drag the floater by its dark backing plate or the move handle (four small arrows) in its bottom-right corner.
The handle is only for dragging, clear of every button, and the pointer turns into the four-way move cursor over it.
Every button waits for the pointer to rest on it for a moment and then shows a short tip saying what it does.
The floater itself is icon-only: results, errors and cancellation hints live in tooltips and accessibility help rather than visible status labels.
Hover over the floater to reveal centered R⌥ and R⇧ shortcuts over faded microphone and camera icons.
During recording, white amplitude bars stay visible instead; pending transcription uses a small writing animation that becomes static with Reduce Motion.

| Control | What it does |
| --- | --- |
| Large round button | Talk to Firstmate: hold, speak, release; or click once to start and click again to send. Double-click also toggles. |
| Stop (square) | Stops the reply being spoken now, and drops any reply queued to be spoken after it. Runs `bin/fm-speak.sh --stop`. |
| Repeat (circular arrow) | Speaks the last spoken reply again through `bin/fm-speak.sh --repeat`, or reports "Nothing to repeat" / "Voice muted" in the main button's tooltip without speaking when unavailable or muted. |
| Recent replies (dropdown arrow, right edge) | Opens icon-only play buttons for the last 10 replies, newest first, with dates and text in their tooltips; click to replay, use Stop/Mute as usual, or click the arrow to close, using `bin/fm-speak.sh --history` and `--replay <number>`. |
| Mute (speaker) | Toggles voice off and on. While muted the icon is a crossed-out speaker on an orange circle, every reply stays text-only, and a reply playing at the moment you mute stops. Runs `bin/fm-speak.sh --mute` / `--unmute`; the setting is per home and survives restarting the floater. |
| Voice volume (right-click or Control-click the speaker) | Opens or closes an icon-only slider (percentage in its tooltip) from 0% to 200% of system volume without changing the Mac's own volume; changes apply from the next line and persist per home through `bin/fm-speak.sh --volume` / `--volume <percent>`, with the reset arrow returning to 100%. |
| Camera (bottom right of the small controls) | Takes a [screenshot](#screenshots) for Firstmate; a stack icon means shots are waiting, while an orange exclamation icon means Screen Recording is missing and clicking opens permission guidance. |

Repeat and the recent list play a reply as soon as you click, from the audio kept when it was first spoken, rather than waiting for Deepgram to make it again.
A reply with no kept audio, such as one spoken by macOS `say`, is spoken again the ordinary way.
The last 10 replies and their audio are kept in this home's private `state/`, readable only by your own account on the Mac; older ones are removed as new ones arrive.

Muting affects voice only.
Firstmate's text replies stay the authoritative ones, and nothing about how Firstmate handles your transcripts changes.
`bin/fm-speak.sh`'s header owns how stop, repeat, the reply history, mute and the voice volume behave.

You can talk while a reply is being spoken.
The reply keeps playing, and it stays out of your message: the floater records with macOS voice processing, which removes the Mac's own playback from the microphone.
macOS always lowers other audio a little while voice processing records; the floater sets that to the minimum, applied only while you are actually speaking, so a reply may dip briefly but is never paused or stopped.
When the Mac's sound output is a Multi-Output Device or a virtual device such as BlackHole, voice processing listens against the Mac's built-in speakers instead.
macOS cannot use a Multi-Output Device for it and picks a device inside it, and against a virtual device it leaves a MacBook's built-in microphone unboosted, so the recording would come out near silent.
Recording starts the moment you press: once the microphone is allowed, the floater gets it ready when it appears and again after your audio devices change, so your first words are kept.
After you release, it keeps listening for a moment, so a last word still being spoken is not cut off.
`desk-floater/Sources/VoiceCapture.swift` owns the capture.

## Hotkeys

| Key | What it does |
| --- | --- |
| Right Option, held | Walkie-talkie: talks to Firstmate for as long as it is held, exactly like holding the large button. Releasing sends. A brief brush of the key (under about a third of a second) sends nothing. |
| Right Command, tapped | Starts dictation; tap it again to finish and type the text, or send it when the cursor is in the Firstmate chat. |
| Right Shift, tapped while you are not typing | Takes a screenshot of the display under the mouse pointer. See [Screenshots](#screenshots). |

These work only while the floater is [active](#activating-the-floater).
The talk, dictation and screenshot hotkeys watch only right-hand keys; left-hand keys keep working as usual unless selected for the activation shortcut.
Right Shift follows the same tap rules as Right Command: held with a letter to type a capital, or held longer than half a second, it is an ordinary Shift press and takes no screenshot.
It also takes no screenshot while you are typing, so a Shift brushed on the way to a capital, a question mark or Return is ignored: a tap within a second and a half of your last key, or followed by a key within half a second, counts as typing.
A tap that stands takes its screenshot half a second after you let go, and two taps within that half second take one screenshot.
While macOS has secure typing on, such as in a password field or a terminal with Secure Keyboard Entry, the floater cannot see your keys, so Right Shift takes no screenshot then; use the Camera control.
A hotkey used as part of a shortcut is ignored: pressing a letter or clicking the mouse within the first third of a second of holding Right Option (to type a special character, or Option-click) cancels that capture without sending anything, and Right Command pressed with another key or a click, or held longer than half a second, is an ordinary Command press.
Once Right Option has been held longer than that, you are talking: a key or a click, even one that opens a menu, leaves the recording running, and releasing Right Option still sends it.
System shortcuts that macOS keeps to itself, such as a quick Right Command-Tab or Right Command-Space, are hidden from the floater and can read as a tap; use the left Command key for those.

## Dictation

Dictation types what you say into whatever text box has the cursor: this terminal, a browser field, a chat window, any app.

1. Put the cursor where the text should go.
2. Tap Right Command.
   The large button turns purple and its white bars pulse with microphone amplitude while it listens.
3. Speak, then tap Right Command again.
   The audio is transcribed through the same Deepgram path, and the text is pasted where the cursor is.
   When the cursor is in the Firstmate chat, the text is sent instead (see [Dictating into the Firstmate chat](#dictating-into-the-firstmate-chat)).

The paste puts the text on the clipboard, sends Command-V to the app you are typing in, then puts back whatever the clipboard held before.
The dictated text is marked transient so clipboard-history tools skip it, and anything a password manager marked concealed or transient is not put back: the clipboard is left without it, so the password manager's own clear-after timer still applies.
If something else is copied during that moment, the floater leaves the new clipboard contents alone.
Without the Accessibility permission the text is left on the clipboard instead, and the main button's tooltip reports "Copied - press ⌘V".
Clicking a floater control does not take keyboard focus from the app you are typing in.

### Dictating into the Firstmate chat

When the text box with the cursor is the Firstmate chat itself, dictation sends the text the way talking to Firstmate does: it is typed into the chat and submitted, and the main button's tooltip reports `Sent`.
It takes the same path and the same safety checks, so a chat showing a question or a permission prompt gets nothing and the text goes to the mailbox instead, see [How transcripts reach Firstmate](#how-transcripts-reach-firstmate).
In every other app, and in any other terminal tab or pane, dictation only pastes, and never presses Return.

The floater treats the cursor as being in the Firstmate chat only when all of these hold at the moment the text is ready:

- Terminal is the frontmost app, and its frontmost tab is the one running the Herdr or tmux session that holds the primary Firstmate.
- That session shows the primary Firstmate's pane as its focused pane.

Terminal is the only app the floater can ask which tab is in front, so dictation into a Firstmate chat shown in any other terminal app is only pasted.
Asking Terminal needs the Automation permission (see [Permissions](#permissions)); without it, the floater cannot tell which tab is in front, so any dictation with Terminal in front is only pasted and the main button's tooltip reports "Typed, not sent - allow Terminal", even in a tab that is not the Firstmate chat.
`bin/fm-desk-voice.sh`'s header owns how the chat is recognised.

## Screenshots

Tap Right Shift, or click the Camera control, to take a screenshot of the whole display under the mouse pointer.
Take several in a row, moving the pointer to another display in between if you like: they stack, and about three seconds after the last one they are sent to Firstmate together as one message, with nothing more to press.
The camera shows a stack icon while shots wait; their count and delivery outcome are available in the main button's tooltip and accessibility value.

The message names each image by its full path, for example `Screenshots: /…/state/desk-voice/shots/<time>-<id>.png /…/<time>-<id>.png`, so Firstmate can open them.
A message with screenshots, with or without words, travels the same way as a voice message: typed into the Firstmate chat, or saved to the mailbox when that chat cannot be reached or, for screenshots alone, holds text you have not sent yet, see [How transcripts reach Firstmate](#how-transcripts-reach-firstmate).

Screenshots combine with talk-to-Firstmate:

- Shots taken while Right Option is held, or while the large button is recording, go with that voice message.
- Shots still stacking when you start talking wait and go with the voice message too.
- Shots taken after you finish talking, while the message is still being transcribed, join it; the message then waits until three seconds after the last shot.
- Talking again while a message waits for its shots ("Adding shots" in the main button's tooltip) adds the new words after the first ones, and the wait starts over from the end of that talk.

The words and the image paths arrive as one message, the transcript first, then the `Screenshots:` paths (on one typed line in the chat, on a line of their own in the mailbox).
A voice message with no shots stacked is sent as soon as it is transcribed, so a shot taken after it has already gone is sent on its own.
Dictation never takes screenshots along: shots taken while dictating are sent to Firstmate on their own.

Screenshots are kept in this home's `state/desk-voice/shots/`, which is gitignored and readable only by you.
Only the newest 30 are kept; each new shot removes the oldest beyond that.
`bin/fm-desk-voice.sh shot` takes them and its header owns that limit.
Nothing is sent anywhere but to this home's Firstmate.

## Permissions

The permissions window opens at launch when any required grant is missing or cannot yet be checked.
Open it again from the microphone menu bar icon's **Permissions…** item or either orange "!" badge; microphone denial also opens it.
It is a populated setup window, not a blank Settings scene.
Each row shows why access is used and whether it is granted; required permissions also distinguish missing from not requested.
Control Terminal is marked optional rather than missing when it is not enabled.
Control Terminal is hidden when Apple Terminal is not installed, and never triggers setup reminders or missing-permission badges.
The rows refresh every second while the window is open and when the floater regains focus.

| Permission | Needed for | Open Settings behavior |
| --- | --- | --- |
| Microphone | Every capture | Requests the native Allow prompt if not yet decided, then opens Privacy & Security, Microphone. |
| Accessibility | Activation chord, hotkeys, and pasting dictation into other apps | Requests access and opens Privacy & Security, Accessibility. |
| Screen & System Audio Recording | Screenshots only, not system audio | Requests access and opens Privacy & Security, Screen & System Audio Recording. |
| Control Terminal (optional) | Only for dictation into Apple Terminal's Firstmate tab | Opens Terminal if needed, requests the native Allow prompt if not yet decided, then opens Privacy & Security, Automation. Enable Terminal under the floater. |

After **Open Settings**, a small floating helper follows the System Settings window.
For Accessibility and Screen Recording, drag the floater's icon/name from that bar into the permission list, then switch it on.
The drag carries the running app bundle, not a shortcut or text path, and its visible name comes from that bundle so renaming the app needs no setup changes.
Microphone and Automation use the system prompt or an existing switch instead; macOS does not accept app drops on those pages.
If the Settings window position cannot be read, the helper falls back to a fixed position near the bottom of the screen.
It stays within the screen, hides while another app is in front, and can be closed independently; closing the permissions window also dismisses it.

Until Accessibility is granted, the hotkeys and paste are off and an orange exclamation icon sits on the talk button; its tooltip explains how to allow them.
The on-screen buttons still work.
The floater checks Accessibility every few seconds and enables the hotkeys as soon as it is granted, without restarting.
Screen Recording has its own orange "!" on the Camera control; screenshots remain off until it is granted.
macOS may only notice a new Screen Recording grant after the floater restarts, so choose "Quit & Reopen" if offered, or restart with `bin/fm-desk-floater.sh`.

### Keeping the permissions across rebuilds

macOS keeps the grants for as long as the floater keeps the same signature, so `bin/fm-desk-floater.sh` signs every floater it launches with the same identity.
It uses the first "Apple Development" certificate in your keychain, the one Xcode creates when you sign in with an Apple ID, so a rebuilt floater keeps its grants and the badges stay away.
To use another certificate, put its name or SHA-1 hash on one line in this home's private `config/desk-floater-signing-identity` (see [configuration](configuration.md#desk-floater-signing-identity-configdesk-floater-signing-identity)).
If that certificate is missing, expired or fails to sign, the launcher says so and falls back to the "Apple Development" one, then to ad-hoc, and the floater still starts.
Without a certificate the floater stays ad-hoc signed and the launcher says so: macOS then ties each grant to that one build, every rebuild (after any change to its code) asks again, and the badges come back.
The first signed build is new to macOS too, so it is asked about once more.
Moving from source to the installed app is expected to preserve grants when both use the same signing identity and `com.firstmate.desk-floater`; a formerly ad-hoc-signed copy or a different certificate requires fresh grants.
macOS can still ask again after an app move or replacement; if it does, grant the installed Starship Floater entry rather than the old source copy.
Removing quarantine does not grant any privacy permissions.
When a build is asked about while Starship Floater already shows as switched on in that list, switch it off and on again, or remove it with the minus button and open the permissions window to add it back.

### Quit & Reopen

"Quit & Reopen", Finder and a login item start the floater without the home the launcher passes it.
The floater then finds its home from where it is: the Firstmate folder holding `desk-floater/.build/Starship Floater.app`.
For an app outside a Firstmate folder, such as `/Applications/Starship Floater.app`, configure the saved paths described under [Prebuilt Homebrew app](#prebuilt-homebrew-app).
Without a valid location it says so and quits rather than guessing.

macOS can reopen any copy it knows under the app's identifier.
The launched source app and the prebuilt release share that identity; quit a running source copy before switching to the installed app.
The launcher selects `/Applications/Starship Floater.app` whenever present and makes macOS forget other copies of the launched identifier before registering the installed app.
Use one copy at a time.
A copy built with `--build-only`, such as one a worker builds to check a change, goes to its own `desk-floater/.build/Starship Floater (test build).app` with an identifier of its own and stays ad-hoc signed, so it never changes the floater you launched and macOS never reopens it in place of this home's floater.
Without an installed app, each source launch also makes macOS forget other copies under the floater's identifier, such as one built by an older version of the launcher, a few seconds after the floater is already up.

## How transcripts reach Firstmate

The floater hands each message, with or without screenshots, to `bin/fm-desk-voice.sh send`, which types it into the primary Firstmate session's own chat pane and presses Enter.
The words arrive at once, even while Firstmate is mid-task, and that pane does not need focus.
Only the session holding this home's session lock is ever typed into, and only after its pane is proven to host that session; the script header owns the resolution and the supported runtime backends.
The pane must also show its chat input, read as empty or holding a draft.
A pane showing a shell or a screen that cannot be read counts as unreachable, because typed words there would become keypresses.
So does a pane showing a selection dialog, such as a permission prompt, a question, or a picker: a pointer on a numbered option, or an `Enter to select` or `Esc to cancel` footer, sends the transcript to the mailbox so it cannot pick an option.

The transcript is sent as the captain's plain words, with no label or marker.
Line breaks and control characters become spaces, so a transcript cannot submit early or press keys.

Claude's grey suggested prompt is not typed text, so a chat box showing only that counts as empty and the message goes straight in.
A message of screenshots alone, with no words, never goes past a draft: while the chat box holds text you have not sent, it goes to the mailbox instead, so a screenshot never interrupts your typing.
When you have a half-typed draft in a Claude chat box, a message with words goes past it: the draft is set aside with Claude's own Ctrl+S stash, the message is sent on its own, and Claude puts your draft back in the box, pasted text and images included.
Your draft is never sent, cleared, or retyped.
The message goes into the emptied box as one paste, so a long voice transcript shows there as a single `[Pasted text #N]` placeholder and is sent whole.
That has one deliberate exception, where text in the box still sends the message to the mailbox: Claude's footer already shows `› stashed`, a draft you set aside yourself.
Stashing again would replace yours, and an existing Claude stash is never overwritten.
If the message cannot be proven in the box before Enter, it is cleared, your draft is put back, and the message goes to the mailbox.
If the box cannot be cleared, or the message has not appeared in it at all, no further keys are sent, so a late paste cannot replace your stashed draft, and the send reports that the submit was not confirmed instead.
Whenever your draft cannot be put back, the send notes that it is still stashed; Ctrl+S in an empty chat box brings it back.
After Enter the send counts as confirmed only once the box is empty or shows your draft again; otherwise it reports that the submit was not confirmed.
With another harness as the primary, a message with words joins the draft and is submitted with it.

When the chat pane cannot be reached, is not showing its chat input, or refuses the text, the transcript goes to the mailbox instead:

| Path | Role |
| --- | --- |
| `state/desk-voice/inbox/*.json` | Pending captain-input transcripts |
| `state/desk-voice/processed/` | After `bin/fm-desk-voice.sh drain` |
| wake `check desk-voice` | Nudges the primary that something landed |

A transcript reaches Firstmate one way only.
Text that was typed and submitted, even when the submit could not be confirmed, is never also saved to the mailbox.
The main button's tooltip and accessibility value report which way it went: `Sent`, `Sent, unconfirmed`, or `Saved for Firstmate` when it went to the mailbox.

A message saved to the mailbox also rings Firstmate, the way a captain inbox note does, so a busy Firstmate picks it up within seconds rather than when its current task ends.
The ring is one short line typed into the Firstmate chat asking it to collect the mailbox now; it carries none of your words.
It is typed only into an empty chat box, never over a question, a permission prompt or your draft, so while the chat cannot take it the ring tries again for about four minutes.
It stops once it is typed or the message has been collected, and it never rings in away or quiet mode, whose own supervision picks the message up.
`bin/fm-desk-voice.sh`'s header owns the ring.

The primary (or you) drains the mailbox with:

```
bin/fm-desk-voice.sh pending
bin/fm-desk-voice.sh drain
```

Drain prints each transcript as plain text (or `--print` for JSON) and moves the file to `processed/`.
Treat the drained text as captain input in the primary conversation.
`bin/fm-desk-voice.sh deliver` writes to the mailbox directly, without trying the chat pane.
Dictation types text only where you put the cursor, sending it only when that is the Firstmate chat, and talk-to-Firstmate types only into the primary Firstmate chat.

## Recordings are never lost

The floater keeps every recording until its words have arrived: typed into the Firstmate chat, saved to the mailbox, or, for dictation, typed or left on the clipboard.
Recordings are made in this home's private `state/desk-voice/recording/` and removed once their words arrive.

When the words do not arrive, the recording is saved instead:

- Transcription failed, for example because the network or Deepgram was down, for a recording at least half a second long. A shorter one reports `Transcribe failed` in the tooltip and is not kept.
- Transcription came back with no words from a recording at least two seconds long. A shorter one is taken as a stray press, reports `No speech` in the tooltip, and is not kept.
- The message could not be delivered at all.

A recording that comes out near silent is the exception: the microphone delivered nothing usable, so it is neither transcribed nor kept, and the main button's tooltip reports `Mic silent - not sent` at once, so you can check the microphone and say it again.
`desk-floater/Sources/Recordings.swift` owns what counts as near silent.

Saved recordings go to `state/desk-voice/unsent/`, readable only by your own account.
A talk-to-Firstmate recording is tried again by the floater itself after about 20 seconds, a minute and five minutes, and the main button's tooltip reports `Saved - retrying` meanwhile.
One that works on a retry is sent to Firstmate as usual, a little later than you spoke it, and the main button's tooltip reports how it went.
After the last automatic try the main button's tooltip reports `Saved, not sent` and the recording stays saved.
A dictation is not tried again by itself, since its words belong where your cursor was when you spoke: the main button's tooltip reports `Saved, not sent` and the recording stays saved until you retry it.
Words held back for screenshots that then fail to send are saved and retried the same way, without the screenshots, which stay in `state/desk-voice/shots/`.
If the floater stops while a recording is being made or transcribed, it saves that recording the next time it starts, unless it is near silent, and, for talk to Firstmate, tries it again.

To see and transcribe saved recordings yourself, or ask Firstmate to:

```
bin/fm-desk-voice.sh recordings
bin/fm-desk-voice.sh retry
```

`retry` tries every saved recording, or only the ones you name, and prints a dictation's words for you to paste.
A saved recording is never removed by itself: it goes only once its words are delivered, or printed by `retry` for a dictation, or when you delete it from `state/desk-voice/unsent/` with its `.json` record.
`bin/fm-desk-voice.sh`'s header owns the saved recordings and the retry.

### Long messages

A message has no length limit: a ten-minute recording is transcribed whole and arrives like any other.
A long one takes longer to transcribe, and a small writing animation runs in the main button until it is done.
The transcription request cannot hang: each attempt gives up after a time that grows with the recording, about five minutes for a ten-minute one, so a slow connection still has time to send a long recording.
An attempt on which nothing has moved for 20 seconds, a little longer for a long recording, also gives up: Deepgram now and then takes a recording and never answers, and the retry usually answers at once, so a short message does not wait for transcription for minutes.
A stalled or timed-out attempt, a dropped connection or a busy Deepgram is retried twice, so a ten-minute recording waits about 16 minutes at worst before it fails.
A recording whose transcription still fails is saved and retried as above.
`bin/fm-deepgram-stt.sh`'s header owns those limits.

## Desk speak-out bound

Spoken replies require a private add-on that is not part of this repository; without it, voice-out stays off.
The Mac floater hides Stop, Repeat, Mute, voice volume and recent spoken replies when that add-on is missing; push-to-talk and screenshots still work.

The register owner truncates the shaped line before any speaker sees it, and
its own default budget is the ~8s one tuned for the glasses, which cuts an
ordinary two- or three-sentence desk outcome mid-message.
So `bin/fm-speak.sh` points that owner at
[`docs/examples/desk-speak-register.toml`](examples/desk-speak-register.toml)
(via `GLASSES_ANNOUNCE_CONFIG`, unless already set) for every desk line.
That example keeps the same URL/path/id and decision refusals but sets the
spoken budget to **30 seconds** and seven sentences (about 78 words at 2.6 wps).
The budget belongs to the desk rather than to the speaker, so it is the same
whichever speaker plays the line, macOS `say` or Deepgram Aura.
Two lines in one turn play one after another rather than overlapping.
`bin/fm-speak.sh`'s header owns that serial lock.

Override the example path with `FM_SPEAK_DEEPGRAM_REGISTER`, or keep the short
glasses cut by exporting `FM_SPEAK_DEEPGRAM_REGISTER=` (empty).
The variable keeps its historical name because it is the published opt-out; it
has never been a Deepgram gate.

TTS model default: `aura-2-thalia-en` (`DEEPGRAM_TTS_MODEL`, from the environment or this home's gitignored `.env`).
STT model default: `nova-3` (`DEEPGRAM_STT_MODEL`, from the environment or this home's gitignored `.env`); per-home vocabulary in `config/stt-vocabulary`, see [docs/configuration.md](configuration.md#speech-to-text-vocabulary-configstt-vocabulary).

## Non-goals

- Always-on open mic / wake word.
- Sending dictated text anywhere but the text box that has the cursor.
- Watching the screen continuously, or computer use: a screenshot is only taken when you ask for one.
- Choosing a window or region: a screenshot is always the whole display under the pointer.
- Replacing glasses voice or the ElevenLabs glasses path.
- Building inside the OpenAI Codex app.

## Related scripts

| Script | Role |
| --- | --- |
| `bin/fm-desk-floater.sh` | Build/launch the floating control; the controls, hotkeys, dictation and screenshot stacking live in `desk-floater/Sources/DeskFloater.swift` |
| `desk-floater/Resources/make-app-icon.sh` | Regenerate the app icon (`AppIcon.icns`, committed) from `AppIcon.svg` and its small-size twin `AppIcon-small.svg` |
| `bin/fm-desk-voice.sh` | Send into the primary chat, screenshot capture, mailbox deliver / pending / drain, and saved recordings: keep / recordings / retry |
| `bin/fm-web.sh` | The localhost chat page, which sends through `bin/fm-desk-voice.sh send` ([web.md](web.md)) |
| `bin/fm-deepgram-stt.sh` | Audio file → transcript, with a bounded, retried request |
| `bin/fm-deepgram-tts.sh` | Text → Deepgram Aura audio |
| `bin/fm-speak.sh` | Captain-facing speak-out (a named `voice` selects `say`, else Deepgram Aura; each the other's fallback), plus `--stop`, `--repeat`, `--history`, `--replay`, `--mute`, `--unmute`, `--muted` and `--volume` |
