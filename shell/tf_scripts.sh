#!/bin/bash

tf_purge_lock() {
    for lockId in $(aws dynamodb scan --table-name terraform-state-lock --query 'Items[*].LockID.S' --output text); do
        aws dynamodb delete-item --table-name terraform-state-lock --key '{"LockID":{"S":"'$lockId'"}}'
    done
}
