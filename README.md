# Inkpick

Inkpick is a Mac app for browsing notes on a reMarkable. It talks to the tablet only over the USB cable, at `http://10.11.99.1`. Handwriting is turned into text on the Mac.

## Connect the tablet

1. Wake the reMarkable and unlock it.
2. Open Settings, then Storage, and turn USB web interface on.
3. Plug the tablet into the Mac with a USB cable.
4. Open Inkpick. The sidebar shows USB connected when the tablet answers.

The web interface has no password. The only path to it is the cable. Turn USB web interface off when you unplug the tablet.

## Use a note

Select a notebook or document. Inkpick downloads the note itself and draws the pages on the Mac. The tablet does not render a PDF. A notebook opens on its last page. The page bar can jump to the first or last page, or to a page number. When the notebook recorded when a page was added, that time is shown there.

- Copy Page puts the current page on the clipboard as an image and as a PDF.
- Transcribe reads every page on this Mac. Typed text is taken from the note when it is there. Handwriting is recognized locally with Apple Vision.
- Copy Text copies the transcript for this page, or the whole note, depending on the inspector.
- The transcript can be edited before you copy it.
- Save PDF writes the pages Inkpick drew.
- Upload adds a PDF or EPUB. The tablet decides the destination folder. Inkpick tells you where the file landed.

Rename, move, and delete are not available. The tablet’s USB web interface does not support them.
