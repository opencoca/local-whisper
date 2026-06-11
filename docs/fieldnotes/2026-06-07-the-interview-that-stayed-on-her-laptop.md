# The interview that stayed on her laptop

*Sage.is Talking turns your voice into text and your text back into voice, on a Mac, without sending a word to anyone. Here is a night when that was the whole point.*

> Nadia is a stand-in. What the app does here is real in Sage.is Talking. The file transcription and read-aloud ship in 1.2.2; the double-tap dictation trigger and the playback keys ship in 1.2.3. The person is made up. The software is real.

It is a little after eleven and Nadia is at her kitchen table with her coat still on. She flew back this afternoon from two days of reporting, and the recorder on the table holds ninety-two minutes of a conversation she promised would stay between her and the person who agreed to talk. That promise is the problem. The fast way to turn audio into text is to upload it to a website, wait, and copy the result. She is not going to do that with this file. Whoever runs that website would have the recording, and so would whoever they answer to.

So she opens the menu bar and drags the `.m4a` onto a small microphone icon.

A wide window appears and the transcript starts filling it, a chunk at a time, her source's voice becoming sentences she can scroll. The wifi is off. It was off on the plane and she never turned it back on, and it does not matter, because nothing here is reaching for a network. The model that does the listening was downloaded once, weeks ago, and lives on her Mac. The work happens on the same Neural Engine that runs the rest of her machine. A ninety-minute interview lands as text in the time it takes her to make tea.

This is the part most dictation tools get wrong for the kind of work Nadia does. They are good, and they are quick, and they route your audio through someone else's servers to get there. For a grocery list that is a fair trade. For a confidential source it is a non-starter, and no amount of polish changes that. Sage.is Talking starts from the other end: the audio and the text never leave the laptop, there is no account, and there is nothing to opt out of because there is no telemetry to begin with.

She did not have to think about any of that tonight. She had to drag a file.

## Both directions

The transcript is only half of what the app is for. A while later, draft open, Nadia has the opposite problem: she has read her own opening paragraph so many times she can no longer hear it. So she selects it, presses Ctrl, Option, Shift and the space bar, and the Mac reads it back to her in one of the Siri-quality voices already built into macOS. The words light up one at a time as they are spoken, and the sentence being read sits centered in a large, high-contrast window she can follow from across the table. Two sentences in she catches a clause that sounded fine on the page and clumsy out loud. She fixes it. That is the trick proofreaders have always used, and it works better when something else is doing the reading.

The same read-aloud lane handles a pasted URL, a dragged-in PDF, or whatever is on the clipboard, and it can write the spoken version out to a `.wav` or `.m4a` if she wants the audio. The dictation lane has a matching button to save the recording she just made. One app, voice to text and text to voice, both running locally.

It is free, and the source is public under the AGPL. If you do not trust a privacy claim you cannot inspect, you can read exactly how this one is kept.

## The shortcut you already press

Apple's own dictation is one shortcut away, and plenty of people set it to the simplest gesture there is: tap the Control key twice. It works. It is also the weak point. The accuracy trails a full Whisper model, and you are stuck with whatever Apple ships.

Sage.is Talking answers to the same gesture. Point its trigger at a double-tap of Control and the habit you already have runs Whisper instead, on your Mac, dropping the text into whatever field your cursor sits in. Tap twice to start, tap twice to stop, and the words are there. If you would rather leave Apple's dictation alone, aim this at a double-tap of Command or Option. The switch costs nothing, not even a new reflex.

The reading side works the same way. While the Mac is speaking, the keyboard's Play/Pause key pauses and resumes it, and Escape stops it.

## What it is honest about

Nothing here is finished, and the project does not pretend otherwise. The download is not yet notarized by Apple, so the first launch needs a right-click and an Open to get past Gatekeeper, which is a small indignity the team has on its list to remove. Pausing playback on one of the system voices can make the highlight drift a beat before it settles, a rough edge the project writes down in the open.

That last one is not getting patched over. The branch this is being written on is wiring in a new, downloadable voice engine called Kokoro, which produces cleaner audio and the precise timing that makes the read-along marker land on the right word every time. After that comes a small iPhone version, already mapped out, since the transcription engine runs natively on iOS and most of the Mac code comes along. Voice cloning, through a separate tool the app will use only if you install it, sits further out.

For now the shape is simple enough to explain in one breath. Hold a key and talk, and your words show up where your cursor was. Select some words and the Mac reads them back. Drag in a recording and read what was said. All of it on your own machine, and none of it anywhere else. Nadia closes the laptop on a finished draft and a recording that is still only hers.

---

*Real today (through v1.2.2): two-way voice, audio and video file transcription, the read-along window, audio export in both directions, custom vocabulary, fully offline. New in v1.2.3: double-tap-a-modifier triggers (including ⌃⌃ as a drop-in for Apple's dictation shortcut) and Play/Pause + Escape playback controls. In progress on `feature/kokoro`: the Kokoro voice engine. Planned: a notarized download, an iPhone app, voice cloning, type-instead-of-paste output. Known rough edge today: pausing a system voice can jitter the read-along highlight. Roadmap lives in [TODO.md](../../TODO.md); shipped history in [CHANGELOG.md](../../CHANGELOG.md).*
