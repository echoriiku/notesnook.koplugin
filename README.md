# notesnook.koplugin

A plugin for KOReader that exports books to Notesnook as structured HTML notes.

Each exported note contains the book cover, metadata, reading statistics, reading timeline, rating, highlights, annotations, and other information gathered from KOReader, creating a complete reading record inside Notesnook.

The plugin uses the official Notesnook Inbox API and performs all processing locally on the device. Network access is only required when sending a note.

---

## Features

* Export any supported book to Notesnook.
* Embed the book cover directly into the note.
* Include metadata such as title, author, series, publisher, and description.
* Generate a reading dashboard using KOReader statistics.
* Include a per-day reading timeline with progress, duration, pace, and page ranges.
* Export ratings, highlights, annotations, and highlight colors.
* Configurable notebook, tags, favorite, and read-only state.
* Confirmation dialog before sending (optional).
* Supports gesture assignment and File Manager integration.

---

## Requirements

* KOReader
* Notesnook account
* Notesnook Inbox API enabled
* A valid Inbox API key

---

## Installation

1. Download this repository.
2. Extract the contents to a directory named `notesnook.koplugin`.
3. Edit `notesnook_config.lua`.
4. Copy the `notesnook.koplugin` directory into your KOReader plugins directory.

| Platform   | Plugin directory                           |
| ---------- | ------------------------------------------ |
| Kindle     | `/mnt/us/koreader/plugins/`                |
| Kobo       | `/mnt/onboard/.adds/koreader/plugins/`     |
| PocketBook | `/mnt/ext1/applications/koreader/plugins/` |
| Android    | `<koreader-data>/plugins/`                 |

5. Restart KOReader.

---

## Configuration

Configure the plugin by editing `notesnook_config.lua`.

```lua
return {
    api_key = "",
    notebook_id = "",
    tag_ids = {},

    confirm_before_send = true,

    favorite = false,
    readonly = false,
}
```

### Required

* `api_key`
* `notebook_id`

### Optional

* `tag_ids`
* `confirm_before_send`
* `favorite`
* `readonly`

---

## Usage

The plugin can be invoked in two ways.

### File Manager

Long-press a supported book and select **Send to Notesnook**.

### Gesture

Assign the **Send to Notesnook** action from KOReader's gesture manager and invoke it while reading.

---

## Exported Note

Each exported note includes:

* Book title and author
* Embedded cover image
* Reading dashboard

  * Rating
  * Reading dates
  * Reading duration
  * Active reading days
  * Reading speed
  * Session statistics
  * Progress efficiency
* Reading timeline

  * Daily reading duration
  * Pages read
  * Reading speed
  * Progress
  * Page ranges
* Book description
* Highlights
* Annotation notes
* Highlight colors

## Screenshots
<img width="800" alt="Screenshot 2026-07-08 at 13-58-34 Notesnook" src="https://github.com/user-attachments/assets/d32f2fbc-bbab-48d9-b9b6-03b4ec8d5005" />
<img width="800" alt="Screenshot 2026-07-08 at 13-58-44 Notesnook" src="https://github.com/user-attachments/assets/ef66ae26-9907-4d42-b29e-9b3cf10dd89b" />
<img width="800" alt="Screenshot 2026-07-08 at 13-59-00 Notesnook" src="https://github.com/user-attachments/assets/17ce8083-9a0f-4d88-9988-b107e7128670" />

---

## Supported Formats

The File Manager action is available for:

* EPUB
* PDF
* MOBI
* AZW
* AZW3
* FB2
* CBZ
* CBR
* DJVU
* TXT
* HTML
* DOCX

---

## Notes

* EPUB covers are extracted directly from the book.
* Reading statistics are obtained from KOReader's `statistics.sqlite3` database.
* All HTML is generated locally before transmission.
* The plugin communicates only with the official Notesnook Inbox endpoint.
* No background services, polling, or scheduled tasks are used.

---

## License

AGPL-3.0 (same as KOReader).
