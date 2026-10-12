# Manual QA — tab strip management (27H1)

- [ ] Open more tabs than fit: `‹ ›` arrows appear; clicking them scrolls; opening a new tab auto-scrolls it into view (no lost tabs).
- [ ] `⌄` all-tabs menu lists every tab (pinned, grouped, loose) and jumps to the selected one.
- [ ] Right-click a tab → Pin: it moves to the icon-only pinned zone on the left and stays visible when the strip scrolls. Unpin returns it.
- [ ] Right-click a tab → New group from this tab: a colored, named segment appears (named after the VM). Right-click the header → Rename, recolor (6 swatches), Ungroup, Close group all work.
- [ ] Right-click a tab → Group all tabs of this VM: all that VM's non-pinned tabs cluster into one group.
- [ ] Add to group ▸ moves a tab into an existing group; the group's tabs stay contiguous; moving the last member out of a group makes the empty group disappear.
- [ ] Drag to reorder: loose tabs reorder among loose; group members reorder within the group; pinned order is menu-only. A cross-zone drop never corrupts the layout.
- [ ] Close others / Close tabs to the right never close pinned tabs.
- [ ] Closing the last tab of a grouped VM still tears down its tunnel (log: "Stopping tunnel"); the emptied group disappears.
- [ ] Spanish: menus, group header, and the rename dialog are translated and not clipped.
- [ ] Existing invariant holds: switching tabs never kills a live SSH session (IndexedStack).

## Notes carried from execution

- **The all-tabs `⌄` button is deliberately shrunk to its icon bounds** (not `VisualDensity.compact`): a larger button steals enough width to trip the overflow logic at narrow panel widths. Acceptable on desktop (mouse); revisit if the strip is ever used on touch.
- **Group ops no-op silently on a stale/nonexistent group or session id** (consistent with `focus`/`close`). Not user-reachable through the current UI, but noted for future callers.
