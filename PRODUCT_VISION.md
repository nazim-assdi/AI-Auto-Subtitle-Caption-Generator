# Product Vision — Creator Studio Edition

## Product identity

A local-first creator workflow, not only an automatic subtitle button. The product is designed around privacy, language breadth, correction, reuse and export.

## What makes this product different as a combination

1. **Private by default:** speech recognition and rendering run on the user's own PC. No video needs to be uploaded to a third-party caption service.
2. **Broad speech recognition:** the language selector is generated from Faster-Whisper's installed multilingual language codes, with Auto Detect.
3. **Creator Vocabulary Boost:** users can supply people, brand, place and technical terms as Whisper hotwords to help recognition.
4. **Human-in-the-loop Transcript Editor:** users correct the segment text and re-render without re-transcribing the full video. Original cue timings are preserved; changed cues receive proportional word timing.
5. **Creator Pulse:** word count, speaking pace, long pauses, language-specific filler-word hints, alignment-probability review words, and heuristic hook-moment suggestions.
6. **Six caption looks and layout controls:** Hormozi, Clean, Neon, Creator, Cinema and Minimal styles; caption position and words-per-line options.
7. **Portable project exports:** MP4, SRT, VTT, ASS, TXT, JSON and Creator Report.
8. **Optional offline subtitle translation:** Argos Translate language packs can be installed locally; translated and bilingual subtitle files are exported without sending the source video to a cloud translation API.

## Honest feature boundaries

- Whisper language support and translation language-pair support are different. Recognition supports the language codes shipped with the selected multilingual model; offline translation is limited to Argos packages installed by the user.
- Word alignment probability is not proof that a recognized word is correct. The report is a review aid.
- Hook candidates and filler-word reports are heuristics, not a promise of virality or a substitute for listening.
- The default CPU Base model is targeted at entry-level PCs. Larger models and offline translation packages need additional disk and memory.
- The app currently has no sign-in or authentication. Keep the backend on a trusted local network and never expose port 8000 to the public internet.
