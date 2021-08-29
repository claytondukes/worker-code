# DNS-API Worker

This repository contains a subset of the code which used to run upon the [https://dns-api.com/](https://dns-api.com/) service.   The service used to allow hosted git repositories to be used to automate DNS records.

In brief the site consisted of several parts which all operated together:

* There were a bunch of git-repositories hosted on the machine itself.
  * Beneath `/repos`.
* There were a bunch of workers which listened for events, and reacted to them.
  * This mostly involved monitoring a Redis instance.
  * For example whenever a user uploaded a new SSH key an action was taken.
  * Or when a git-repository received a push then an action would be taken.
* There was a MySQL database service
  * This contained details of all users, their domains, & etc.
* There was a web application which was used to interface the end user with their domains, password, email, etc.
  * All content stored in the MySQL database.
  * The Application was written in Perl, using the [CGI::Application](https://metacpan.org/pod/CGI::Application) framework.
* There was a second web application written in Ruby which handled [stripe](https://stripe.com/) integration.


## Rough Operation

Ignoring all the parts which I'm not going to release, or discuss, then the pieces that remain are pretty simple:

* Assume there is a redis instance.
* When a user runs a `git push` then a receive-hook runs.
  * This connects to redis and makes a new addition to the `HOOK:JOBS` set.
* There is a worker running all the time, polling the `HOOK:JOBS` set
  * When a new entry is received it reads it, so it knows which repository to operate upon, and has a UUID to use for storing the output/logs.

In short I'm using redis sets as a queue, which works really well at a small scale.

## Deployment

The whole code was stored in a single repository, broken into distinct directories for the website, the receiver, the workers, etc.

Code in the machine used several fixed directories:

* Releases of the complete codebase:
  * `/srv/release-123455`
  * `/srv/release-123456`
  * The most recent release would have a symlink pointing to it
    * `/srv/current`
    * So `/srv/current/common` would always point to the most recent common libraries, for example.
    * Similarly `/srv/current/site/htdocs` would be the Apache server-root.
* The hosted (bare) repositories:
  * `/repos/steve`
  * `/repos/cdukes`
  * `/repos/bob`
  * `/repos/example`
* The temporary working location
  * `/git`
  * `/git/steve`
  * `/git/cdukes`
* A place for per-account notes.  If there was a file "`/notes/steve`" it would be displayed on all pages of the website when the user `steve` logged in.  Mostly to say things like "Pay your bills", or "You're a sponsored account".
  * `/notes`
  * `/notes/root`
  * `/notes/steve`


## Actual Code

Hopefully the above gives a flavour of how things were arranged, we'll now link to the code.

As mentioned there were a bunch of repositories, one for each user, stored beneath `/repos/$username`.  These were bare repositories so I'd copy a hook-script into place for each one:

* [git-hook/](git-hook/)
  * This would connect to redis and record a push happened.
* [worker/](worker/)
  * I had numerous worker scripts which listened to various redis sets
  * These would do things like create a new repository for a new user (by watching the `NEW:USER` set), etc.  I'm not sharing all of these.
  * This script is the one that would react to the git-pushes, and make the DNS changes


### git-hook

Nothing much to say here, it would create a JSON object which would get added to the redis `HOOK:JOBS` set:

    { uuid: "11-22-33-44-55...",
      user: "steve",
      repo: "/repos/steve" }

### worker

This would poll the redis-set every few seconds, pulling the next job to process from the queue.  In short it would:

* Look for the user, `steve` in the example above, and ensure it existed
  * By looking in the database.
* Ensure the user hadn't expired, been banned, etc.
* Look at `/git/$user` and run `git pull` if it existed.
  * Building up a list of files/domains that had changed in the most recent commits
* If `/git/$user` didn't exist it would run a full clone:
  * "`mkdir /git/$user; cd /git/user; git clone /repos/$user`"
* Scan the contents of `/git/$user/zones/*.*`
  * Ignoring example.*, and other exceptions
  * For each zone, parse it for DNS records and do the necessary syncing with AWS
* Write any output to a temporary object.
* Once complete the temporary logs would get added to the MySQL database with the appropriate UUID so they could be visible.
* Finally it would make sure each domains' nameservers were stored in the MySQL database
  * Because the users need to know what to set them to.



## Running This?


* Well the code for the git-hook is trivial.
* You already have a copy of the git repository.
  * So hosting that somewhere is simple, with your own SSH key, etc.
  * Adding the hook-script is simple.
* The harder part is the worker.
  * At the start clone this repository somewhere, and make `/srv/current` a symlink to point to it.
    * That way `/srv/current/common` will be a valid location for the shared-libraries/packages.
  * Of course you're missing the MySQL database.
  * You're probably expecting logs to be handled somewhere.
  * You'd need to remove anything that called "Common::*"
    * i.e. Attempting to lookup whether the user exists, isn't banned, etc.
  * Basically you'll want to edit/examine [worker/Hook.pm](worker/Hook.pm) to remove the references to common-tests.
  * Starting the worker will be a matter of
    * `/usr/bin/perl -I. -I/srv/current/common/ /srv/current/worker/webhook-processor`

Now I look again you might also enjoy `webhook-processor-fake`.



## Misc Links

Here's a dump of the MySQL table-structure, for reference:

* [sql/][(sql/)
