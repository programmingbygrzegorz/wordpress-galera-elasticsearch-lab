#!/bin/bash
# Hook po przyjęciu pusha: wdraża tylko gałąź main.
while read -r _old new ref; do
  if [ "$ref" != "refs/heads/main" ]; then
    echo "Pomijam $ref – wdrażana jest tylko gałąź main"
    continue
  fi
  if [ "$new" = "0000000000000000000000000000000000000000" ]; then
    echo "Usunięcie gałęzi main – nic nie wdrażam"
    continue
  fi
  /usr/local/bin/wp-deploy "$new"
done
