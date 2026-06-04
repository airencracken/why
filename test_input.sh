#!/bin/bash

greeting="Hello"
name="World"
count=3

say_hello() {
    local msg="$1"
    echo "$msg, ${name}!"
    echo "Count is $count"
}

add_numbers() {
    local a="$1"
    local b="$2"
    local result=$((a + b))
    echo "$result"
}

for ((i=0; i<count; i++)); do
    say_hello "$greeting"
done

sum=$(add_numbers 5 7)
echo "Sum: $sum"

name="Everybody"
say_hello "Hi"
