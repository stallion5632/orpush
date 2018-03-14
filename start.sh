#!/bin/bash

logdn="logs"
if [ ! -d "$logdn" ]; then
	mkdir "$logdn"
fi

openresty -p .
