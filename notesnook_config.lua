-- notesnook_config.lua
-- Copy this file and rename it to notesnook_config.lua (remove the .example extension if present).
-- Fill in your Notesnook Inbox API key and target notebook ID.

return {
    -- Your Notesnook Inbox API key.
    -- Found in Notesnook Settings > Inbox > API Keys.
    api_key = "YOUR_API_KEY",

    -- The ID of the notebook where book notes will be created.
    -- Right-click a notebook in Notesnook and choose "Copy ID".
    notebook_id = "YOUR_NOTEBOOK_ID",

    -- (Optional) Tag IDs to apply to every note created.
    -- Right-click a tag in Notesnook and choose "Copy ID".
    -- Example: tag_ids = {"abc123", "def456"}
    tag_ids = {
    	"",
    	},

    -- Whether to show a confirmation dialog before sending to Notesnook.
    -- Set to false to send automatically without prompting.
    confirm_before_send = true,

    -- Whether to mark the note as a Favorite in Notesnook.
    favorite = false,

    -- Whether to make the note read-only in Notesnook.
    readonly = false,
}
