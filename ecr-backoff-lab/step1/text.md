## Before you start

So your interviewer can follow along, run:

```
share-terminal
```{{exec}}

If it asks about the host's authenticity, type `yes`. Then copy the full `ssh ...` line it prints and paste it into the interview chat. If your interviewer's connection needs approval, accept it.

The session is read-only: your interviewer sees what you do but can't type anything. Do the whole exercise inside this session. If you lose the join command, run `upterm session current`.

## Your mission

1. Find out why the `payments-api` pods aren't running.
2. Fix the problem so both replicas become available.
3. Explain the root cause to your interviewer and how you'd prevent it from happening again.

Think out loud: how you investigate matters as much as the fix.

### Rules

- Don't change the deployment's image or tag.
- Your fix must work on any new node that joins the cluster.
- Work with `kubectl` and `aws`. Host configuration (containerd, `/etc`, system services) is out of scope.

When you think you're done, click **Check**.