# Lyrics Translation

Lyrics translation is an opt-in Labs feature that fills in translations for the lyric lines that lack one. It is off by default. Pick what translates them from Preferences > Lab > Lyrics translation > Translation:

- **System Translation** translates on this Mac with the system's Translation framework. It needs macOS 26 or later, costs nothing, and sends nothing anywhere.
- **AI (selected service)** uses the backend selected in the shared AI service settings: an OpenAI-compatible endpoint or Apple's on-device Foundation Models.

One engine runs at a time. Both translate into the target language set in the same box, zh-Hans when the field is left blank, and only lines without a translation in that language are translated; a translation that names no language counts as one. The target language is separate from the display language set in the same box: the target language decides which language is generated, while the display language decides which of the translations a file carries is shown in the desktop lyrics, the Apple Music-style window, the widget, and the iTunes export, and in the lyrics window when it is Chinese. Leaving the display language blank shows the translation that covers the most lines, ties going to the language code that sorts first; a line without that translation falls back to one that names no language.

Translations are saved with the lyrics. Lyrics embedded in a track, or read from a file beside it while writing back to that file is off, are saved to the lyrics library instead, and the translations are read back from that copy the next time the track plays, so those lines are not translated again.

Adding a translation does not change how the lyrics rank against other search results. LyricsKit ranks lyrics that come with a translation above lyrics that do not, which rewards a provider for supplying one; lyrics that LyricsX translated keep the rank they had before, so a better result that arrives during the priority window can still replace them.

## System Translation

System Translation only uses languages that are already downloaded to this Mac. When the lyrics need a pair of languages that is not, the status line in the Lab pane names the pair and a Download… button appears beside it; it brings up the system's own download prompt over the Settings window, and the lyrics are translated again once the download is done. Translation languages can also be managed in System Settings > General > Language & Region > Translation Languages.

The lyrics are translated from the language they were recognized as being in, so a song needs only that language and the target downloaded. A line that comes back exactly as it went — one already in the target language, or romanized lyrics the models cannot read — is not saved as a translation.

A line in another language, such as the English line of a Japanese song, goes to the translator along with the rest. On macOS 26.7 it comes back translated. On macOS 27.2 the Japanese-to-Chinese translation hands an English line back as it was, so that line goes without a translation; the probe `anEnglishLineInAJapaneseSongIsTranslatedWithTheRest` records this as a known issue, and fails once a macOS release translates the line again.

Some pairs are not supported by the framework at all, Traditional to Simplified Chinese among them on macOS 26.7; the status line says so. On macOS 26.4 and later the framework is asked for its high-fidelity strategy, which uses Apple Intelligence where it is available and falls back to the traditional models where it is not.

System Translation starts as soon as lyrics appear. If the automatic search replaces them while it runs, the result is discarded.

## AI translation

When AI translation is chosen, LyricsX uses an immutable snapshot of the selected backend for that translation run. Changing backends cancels obsolete work; it does not replace translations already saved for the target language.

### Apple on-device model

Choose **Apple on-device model** in Preferences > Lab > AI service > Configure AI service…. This backend calls the native Foundation Models framework and `SystemLanguageModel.default` directly. It requires macOS 26 or later and an available Apple Intelligence model on a supported Mac. The form reports current model availability, supported languages and context size; unavailable models remain selected and fail visibly rather than falling back to a remote service.

Local mode does not use an endpoint, API key, Keychain, `fm` server or Private Cloud Compute. The original remote endpoint/model/key are retained for switching back, but are not accessed by a local request. Each request gets a fresh model session. Translation supplies its own output schema; the local adapter uses Foundation Models guided generation rather than asking free-form text to look like JSON. Invalid results are never repaired by extracting text fragments or written into the lyrics. Context-limit errors use the existing bounded split path, cancellation discards stale work, and unsupported-language, refusal and model-unavailable errors are reported without an unbounded retry. The system Translation engine remains separate.

### OpenAI-compatible service

The remote backend sends eligible lyric lines to the configured OpenAI-compatible chat-completions endpoint. The endpoint receives lyric text, the configured prompt, model name, and source/target language information; it does not receive playback history or account credentials other than the API key required by that endpoint.

The API key is stored in the macOS Keychain and is bound to the endpoint's origin. It is sent only as a Bearer authorization header. LyricsX does not include API keys, request bodies, or response bodies in logs. Remote providers may retain submitted lyrics and may charge for requests; use only a provider and endpoint you trust. HTTPS is required except for loopback development endpoints.

The endpoint, default model and API key are configured from Preferences > Lab > AI service > Configure AI service…. This shared connection can be configured and tested while translation is off or uses System Translation; saving it does not enable translation. Connection-test status is separate from translation status.

The translation prompt remains under Preferences > Lab > Lyrics translation > Translation prompt…. Target and display languages stay in the translation box. Existing endpoint/model preferences and Keychain entries are retained without a storage migration. Missing or unknown backend preferences retain the OpenAI-compatible default. Saving a backend never enables a feature automatically.

Requests are split into batches of at most 24 lines and 32 KiB of source-line JSON. Local translation starts as soon as eligible lyrics appear. For the remote backend, while an automatic search can still replace the lyrics on screen — during its priority window, five seconds by default — nothing is sent; translation starts once the window closes or the search ends. The search that the next-candidate shortcut starts does not change this wait: it is the automatic search's window or end that lets translation start. Transient network failures and HTTP 429/5xx responses receive up to three attempts with exponential backoff, and oversized or malformed batch responses are split into smaller requests, but one song never makes more than three requests per batch. Valid indexed translations are kept even when other lines are missing or malformed; failed lines remain untranslated and are reported in the Lab pane. A line the endpoint hands back unchanged — one already in the target language — is not saved as a translation, as with System Translation, and does not count as failed. When no line comes back at all, the lyrics and their file are left as they were, and the Lab pane says why — for example, the HTTP status the endpoint answered. A temporary Keychain access failure is retried and reported in the UI without disabling the feature or changing its persistent preference.

Requests to api.openai.com send their token limit as `max_completion_tokens`, which OpenAI's reasoning models require; every other endpoint receives `max_tokens`.

## Tests

To run the pure policy tests, use:

```sh
cd LyricsXPackage
swift test --filter LyricsXFoundationTests
```

The suite includes probes that run System Translation against the real Translation framework. Which of them run depends on the languages the Mac has downloaded: each covers one state, such as Japanese to Simplified Chinese being downloaded or not, and skips itself in any other.
