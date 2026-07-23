#!/bin/bash
function greet() {
  name=$1
  if [ $name == "world" ]; then
    echo "Hello $name"
  fi
  return
}
greet $1
