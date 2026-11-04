# File selection shortcuts

The in-app Mac send picker, Mac **Phone files**, and Android attach picker support ranges and
keyboard selection. Android modifier shortcuts require a keyboard and pointer. System **Browse…**
panels keep the operating system's own shortcuts.

| Action | Mac | Android with a keyboard |
| --- | --- | --- |
| Select a continuous range | Shift-click its first and last item | Shift-click its first and last item |
| Toggle a separate item | ⌘-click | Ctrl-click |
| Add a range to separate picks | ⌘Shift-click | Ctrl+Shift-click |
| Select the loaded files | ⌘A | Ctrl+A |
| Move through items | Arrow keys | Arrow keys |
| Extend or shrink a range | Shift + arrows | Shift + arrows |
| Go to the beginning/end | Home/End; Fn+Left/Right on compact keyboards | Home/End |
| Extend to the beginning/end | Shift + Home/End | Shift + Home/End |
| Clear selection | Escape | Escape |

A range includes both endpoints and follows the displayed order. You can hold Shift before the
first click, extend in either direction, or move the endpoint back to shrink the range.

In the send pickers, a plain click/tap continues to toggle a pick; numbers show the send order.
In Mac **Phone files**, a plain click selects one item. A context click or drag on an already
selected item keeps the multiple selection. Opening a different phone, folder or section retires
the previous range anchor.

Selection shortcuts act while a file item or file list has keyboard focus. Text fields, target
controls and menus keep their normal keyboard behavior. On Android, arrows move focus and Space
or Enter toggles the focused item. In the Mac send picker, Space toggles the focused item and
Return keeps its existing Send action. In **Phone files**, Space previews, Return opens the
focused file/folder, and ⌘Y opens Quick Look. Escape closes a preview before clearing its selection;
an empty selection lets the send picker's normal dismissal proceed.

Select All covers the currently loaded context, without fetching the rest of a library. In the
Android attach picker it adds eligible files from the current tab and keeps picks from other
tabs, up to the existing 100-item limit. Unavailable folders and files without access are excluded.
On Mac, files repeated across the send picker's groups appear once and receive one selection badge.

These changes are on `rr/roadmap-call-media`; release and live-device acceptance are pending.
