---
status: proposed
---

# Anonymous Submissions still store their author

An Anonymous Wall Post or Event Quote still records `author_id`. Only the public display hides it: the public reads the `public_wall_posts` and `public_event_quotes` views, which return approved rows only and blank out the author when `is_anonymous` is true. The base tables can be read only by the author and Moderators.

We chose this over truly anonymous (authorless) storage so that Moderators can act on harassment and spam, and so authors can see and delete their own Submissions. The promise to Members is "other members never see who you are", not "nobody can know", and the submit form says so plainly.

## Consequences

Row Level Security hides whole rows, not single columns. So no policy may ever give the public a `select` on the base tables, or the author would leak. Public reads must go through the views.
