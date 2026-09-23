# Incident: payments-api won't start

Monday, 9 AM. The payments team rolled out `payments-api` in the `payments` namespace, and the pods won't start. `payments-worker`, which uses **the same image**, keeps running just fine.

The image lives in a private **Amazon ECR** repository. The AWS CLI on this machine is already authenticated as the on-call user.

Wait for the terminal to say the environment is ready before you start.
