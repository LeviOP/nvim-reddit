# nvim-reddit

## todo:

### important project niceties
- write a real readme
- better configuration
  - configurable highlights
  - configurable margins
  - move refresh token into the correct place.. blehhh
  - type config defaults / optionals correctly
- handle duplicate buffers
  - maybe allow reloading?
- make sure bottom of thing is visible in post mode (when "scrolling" down)
- show errors onscreen instead of printing (and use vim.notify)

### feature parity with old reddit
- fix some issues with richtext rendering
  - zwsp after newline doesn't turn newline into space? something weird (handle whitespace more accurately)
- handle nsfw/spoiler links
- support commenting (and posting)
- handle post types correctly
  - handle crossposts
    - crossposts will have post_hint as link sometimes, apparently (maybe all the time on main page?)
- handle rich:video and similar
- support contest mode
- visibly indicate when post is archived
- visibly indicate when post is locked
- provide way to show inline images in post body
- only show link with sticked text on subreddit
- handle table element
- fix problem where open is not set until image has loaded (leading to desync on first image load while going up and down)

### potential enhancements
- show `removed_by_category`
- maybe cache blocks for comments and links (instead of just expando content)
- maybe address ueberzug image render failing directly after resizing terminal window
- maybe indicate when `more` children returned nothing
- maybe make foldtext children the number of decedents instead of direct children (like official reddit ui)
- handle buffer being open in multiple windows
- maybe render directly instead of rendering text and shifting it around (luajit is very fast :)
- maybe optimize all table accesses / insertions (it's already super fast though)
- maybe show thumbnails? (probably not)
- maybe show comment depth / parenting with background color change or "tree lines"
- maybe don't show flairs on user pages (like official reddit ui does)
- maybe show flairs on the correct side of the post title (requires getting /about of subreddit)
- add "hovers" for various stuff
- support mouse
- maybe handle custom emojis
- handle score digit count being higher than score margin (no reddit post has ever gotten enough upvotes for this to happen, but...)
- allow for rounded borders on flairs and other badges and stuff
- attach spoilers to their thing instead of the global buffer (maybe anti-pattern?)
- handle blockquote spoiler (not spoilered in new reddit)
- add mark/hl_group for gallery caption
- display polls (there is no way to vote, but you can get results after voting on official client)

### codebase maintenance
- standardize variable/parameter names to make understanding offsets (0 or 1 based, column or byte based, abstract or direct data, etc.)
- use style linter
- maybe make separate wrapped type for state stored on things to reduce confusion
- further collapse some mark insertion in richtext rendering
- only use async.run where nessecary instead of just blanket over everything
