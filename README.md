# CrossPoint Sync (KOReader plugin)

Copy the `crosspointsync.koplugin` folder to KOReader's `plugins/` directory, restart KOReader,
then **Tools → CrossPoint Sync → Account & server**.

The server URL, username and password have no defaults and must all be entered
(use the same ones as the web reader). Nothing syncs until all three are set.
Turn off KOReader's built-in *Progress sync* so progress is not uploaded twice.

## Where things are

**Book open (Tools → CrossPoint Sync):** sync everything, push / pull progress, highlights and
bookmarks, book info, reading status, reading stats.

**No book open (file manager, Tools → CrossPoint Sync):** account & server, *Push all books
(not unread)*, send reading stats. "Push all" goes through the reading history, skips books that
were never started, and does not overwrite progress when the server is further ahead.

**Long-press a book in the file manager:** CrossPoint: progress / highlights / book info / reading stats.
(Needs a KOReader version that supports `addFileDialogButtons`; without it the entries just don't appear.)

**Same book under another file name:** if the server has no progress for this file, the plugin
looks for a record with the same title and author (same matching as the web reader) and offers
to go there. Later pushes also write progress under that other id, so the other file finds it.
Setting: *Settings → Same title and author under another file name*.

## Limits

* Covers and print page counts can't be pushed: the sync server's API has no field for them
  (documents only take title, author, filename and filesize).
* Books that are not open have no rendered layout, so for them page-in-chapter hints are left out
  and highlight positions are estimated from the page number KOReader stored.
* "Push all" only knows books in KOReader's reading history.
