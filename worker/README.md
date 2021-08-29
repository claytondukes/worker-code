Hook Job
--------

When a git-push is initiated by the user a git-hook is executed.

The hook will create a random UUID, then store that UUID in a JSON
hash:

    {  "uuid": "12344...",
       "user": "root",
       "url": "/repos/root"
    }

This will be added to a Redis queue, where the worker will pull it off.



Dependencies
------------

The hook operation runs on the main website, which is perfectly
fine at the moment.  In the future it might be that we'd create
a second host to execute the jobs.

Moving things to a second host would be pretty straightforward,
but there will need to be changes:

* The web-host and the git-host must share the Redis queue.
   * Because the web-UI can be used to trigger a re-run.

* The web-host and the git-host must share the MySQL database.
   * Because the output of the job is inserted into MySQL for
     display in the UI.

At the moment the git-repositories are cloned via:

    git clone /repos/$user

If the git repositories were on a separate host that would still
work.

There is also some common code which is used:

* DNSAPI::User
   * To see if a username is valid.
   * To see if a user exists.
   * To see if a user is active, and not expired.

We could drop that dependency if our `bin/process-users`, which is
responsible for changing "trial" to "expired" states, etc, wrote
out a file:

    user: root     status:paid
    user: rails-se status:sponsored
    user: dead     status:expired

That would be simple to do, but that status file would need to
be updated whenever a user changed their state.

