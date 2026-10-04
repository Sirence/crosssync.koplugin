# CrossPoint Sync (KOReader plugin)

CrossPoint Sync is a KOReader plugin that syncs your reading progress, highlights, bookmarks, reading status and reading stats with a CrossPoint sync server.

Copy the `crosspointsync.koplugin` folder to KOReader's `plugins/` directory, restart KOReader,
then **Tools → CrossPoint Sync → Account & server**.

The server URL, username and password have no defaults and must all be entered
(use the same ones as the web reader). Nothing syncs until all three are set.
Turn off KOReader's built-in *Progress sync* so progress is not uploaded twice.

## Features
**Progress Sync**
* When you open a book and wifi is on, it checks the server and goes to the remote position if that is further ahead. You can choose to be asked, to go there automatically, or to do nothing.
* Progress is pushed when you close the book or the device suspends, and optionally a configurable delay after your last page turn, but only if wifi is on.
* Manual push and pull are available from the menu and as gesture actions.
* Books are matched by the MD5 of the file name (the CrossPoint default) or by KOReader's binary hash, and progress is also stored under the other id so both kinds of device find it.
* Series prefixes are stripped from pushed titles so the open library can properly match

**Highlights, bookmarks and book info**
* Highlights (with notes and chapter) and bookmarks are sent to the server (Called Clippings in the app)
* Title, author, file name and file size are sent as book info.

**Reading status**
* You can set Reading, Paused, Finished, Did not finish, or Automatic from the menu.
* KOReader's own "On hold" and "Finished" markers are forwarded automatically.

## Where things are

**Book open (Tools → CrossPoint Sync):** sync everything, push / pull progress, highlights and
bookmarks, book info, reading status, reading stats.

**No book open (file manager, Tools → CrossPoint Sync):** account & server, *Push all books
(not unread)*, send reading stats. "Push all" goes through the reading history, skips books that
were never started, and does not overwrite progress when the server is further ahead.

## Limits

* Covers and print page counts can't be pushed: the sync server's API has no field for them
* Books that are not open have no rendered layout, so for them page-in-chapter hints are left out
  and highlight positions are estimated from the page number KOReader stored.
* "Push all" only knows books in KOReader's reading history.
