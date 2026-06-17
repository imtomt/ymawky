#!/bin/sh

while IFS=: read -r code title msg; do
    printf "$code $title ($msg) -> err/$code.html..."
    sed -e "s/{{CODE}}/$code/g" \
        -e "s/{{TITLE}}/$title/g" \
        -e "s/{{MSG}}/$msg/g" \
        err/template.html > "err/$code.html"
    echo " done"
done <<EOF
400:Bad Request:the rats didn't understand you
403:Forbidden:the rats won't let you do that
404:Not Found:the rats ate this page
408:Request Timeout:the rats grew bored
409:Conflict:the rats found a conflict
411:Length Required:the rats need the length
413:Content Too Large:that's too big for tiny rats
414:URI Too Long:that's too long for tiny rats
416:Range Not Satisfiable:that range is outside of these rats' scope
418:I'm a Teapot:rats are drinking tea in the garden, please wait warmly...
431:Header Header Fields Too Large:tiny rats need tiny heads
500:Internal Server Error:the rats chewed the server's wires
501:Not Implemented:the rats haven't learned how to do that
502:Bad Gateway:the rats broke this page
503:Service Unavailable:the rats are currently busy
505:HTTP Version Not Supported:the rats are too old skool
507:Insufficient Storage:the rats can't store that anywhere
EOF
