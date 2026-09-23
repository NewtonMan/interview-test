## Before you start

So your interviewer can follow along, run:

```
tmate
```{{exec}}

Inside the session that opens, generate the link and paste it into the interview chat:

```
share-terminal
```{{exec}}

The link is read-only: your interviewer can see what you do but can't type anything. Do the whole exercise inside this session.

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
