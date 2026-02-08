# muffin.nvim

A popup window that provides breadcrumbs-like navigation in keyboard-centric manner.
Inspired by [hasansujon786/nvim-navbuddy].

![demo](https://github.com/user-attachments/assets/ead54ffa-ce05-48aa-abc8-fbe8330420be)

## Install

With [echasnovski/mini.deps]:

```lua
MiniDeps.add("metafates/muffin.nvim")

require("muffin").setup()
```

With [folke/lazy.nvim]:

```lua
{
    "metafates/muffin.nvim",
    opts = {}
}
```

Installing [echasnovski/mini.icons] is suggested to show icons and enable highlighting.

See [mini.icons installation](https://github.com/echasnovski/mini.icons?tab=readme-ov-file#installation).

## Usage

Muffin provides the following functions:

```lua
--- Opens a popup with document symbols.
--- No-op if already open.
function Muffin.open() ... end

--- Closes the current popup.
--- No-op if already closed.
---@return boolean closed Indicates if popup was closed.
function Muffin.close() ... end

--- Opens a popup if it was not opened, closes otherwise.
function Muffin.toggle() ... end
```

You may want to set a bind for toggling this popup:

```lua
vim.keymap.set("n", "T", function()
    Muffin.toggle()
end, { desc = "Toggle Muffin popup" })
```

### Keys

When popup is opened, you can use the following keys for certain actions:

| Key | Action |
| --- | ------ |
| <kbd>c</kbd> | Toggle comment on selected symbol |
| <kbd>f</kbd> | Toggle fold on selected symbol |
| <kbd>q</kbd> | Close popup |
| <kbd>h</kbd> | Go back |
| <kbd>gh</kbd> | Go back to root symbol |
| <kbd>l</kbd> | Go forward |
| <kbd>gl</kbd> | Go forward to the innermost symbol |
| <kbd>return</kbd> or <kbd>o</kbd> | Close popup and leave cursor at selected symbol |

You can't rebind these keys _yet_.

## To do

- [ ] More actions. For example copying and reordering.
- [ ] Allow rebinding built-in keys.

[echasnovski/mini.icons]: https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-icons.md
[folke/lazy.nvim]: https://github.com/folke/lazy.nvim
[echasnovski/mini.deps]: https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-deps.md
[hasansujon786/nvim-navbuddy]: https://github.com/hasansujon786/nvim-navbuddy
