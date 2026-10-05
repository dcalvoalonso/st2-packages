Changelog
=========

in development
--------------

Added
~~~~~

Changed
~~~~~~~

 * Updated 3rd party services to tested/supported version for StackStorm core:
     - mongo v8.2
     - rabbitmq v4.2
     - redis v8.10
   Contributed by @nzlosh

 * Updated pip to 26.2.1 in the st2 virtualenv for deb and rpm packages.

 * Updated the install scripts to MongoDB 8.2 (was 7.0).

 * Updated the install scripts to nginx 1.31 from the nginx.org mainline repository
   (was the stable repository, 1.30).

 * Updated the install scripts to Node.js 24.x for st2chatops (was 20.x).

 * Added systemd generators for st2auth, st2api, st2stream service unit files.
   Contributed by @nzlosh #762

Removed
~~~~~~~

* Removed focal and rocky8
  Contributed by @nzlosh + @skiedude #761

* Removed jammy (Ubuntu 22.04), as StackStorm now requires Python 3.11 or 3.12.


v3.9
--------------

Added
~~~~~
* Add Ubuntu Jammy packaging
  Contributed by @mamercad
