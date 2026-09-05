#!/bin/sh
if [ "$1" = "d" ]; then
    crypt_action="decrypt"
    echo "Decrypting vault files..."
else
    crypt_action="encrypt"
    echo "Encrypting vault files..."
fi
ansible-vault $crypt_action group_vars/**/vault.yml