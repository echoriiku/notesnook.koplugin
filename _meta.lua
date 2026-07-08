local _ = require("gettext")
return {
    name = "notesnook",
    fullname = _("Notesnook Sync"),
    description = _([[Sends book notes to Notesnook when you finish a book.
When you mark a book as Reading, the plugin records the start date.
When you mark it Finished, it compiles the book title, cover image,
metadata, and all highlights into a note and posts it to your
Notesnook Inbox.]]),
}
