#!bin/bash

# Example curl request to get tokens

curl --location --request POST 'https://faucet.testnet.iota.cafe/gas' \
--header 'Content-Type: application/json' \
--data-raw '{
    "FixedAmountRequest": {
        "recipient": "<YOUR IOTA ADDRESS>"
    }
}'
