-- White-label configuration per inbox. Lets a tenant brand the visitor widget
-- (logo, agent avatar, font, bubble radius, custom CSS) from the admin console
-- instead of hard-coding values in every embed snippet.
alter table inbox
  add column if not exists logo_url varchar(512),
  add column if not exists avatar_url varchar(512),
  add column if not exists font_family varchar(200),
  add column if not exists bubble_radius int check (bubble_radius between 0 and 40),
  add column if not exists custom_css text;
