import json
import ospaths, os, parseopt2

var resourceNewPath: string
var tilesetNewPath: string
var currentLocation: string

proc moveImageFile(jstr: JsonNode, k: string, pathFrom: string = "") =
    var path = jstr[k].str
    let spFile = splitFile(path)
    var jPath = resourceNewPath & '/' & spFile.name & spFile.ext
    let copyTo = currentLocation & '/' & jPath

    if pathFrom.len > 0:
        jPath = spFile.name & spFile.ext

    jstr[k] = %jPath

    if pathFrom.len > 0:
        path = pathFrom & '/' & path

    echo "copy image file from ", path, " to ", copyTo
    createDir(currentLocation & '/' & resourceNewPath)

    copyFile(path, copyTo)

proc moveTilesetFile(jstr: JsonNode, k: string)=
    let path = jstr[k].str
    let spFile = splitFile(path)
    let jPath = tilesetNewPath & '/' & spFile.name & spFile.ext
    let copyTo = currentLocation & '/' & jPath
    jstr[k] = %jPath

    echo "copy tileset file from ", path, " to ", copyTo
    createDir(currentLocation & '/' & tilesetNewPath)
    copyFile(path, copyTo)

proc readTileSet(jn: JsonNode, pathFrom: string = "")=
    let spFile = splitFile(pathFrom)
    if "image" in jn:
        jn.moveImageFile("image", spFile.dir)

    elif "tiles" in jn:
        for k, v in jn["tiles"]:
            v.moveImageFile("image", spFile.dir)

    if pathFrom.len > 0:
        writeFile(pathFrom, $jn)

proc readTiledFile(path: string)=

    let tmpSplit = path.splitFile()

    currentLocation = tmpSplit.dir
    resourceNewPath = "assets"
    tilesetNewPath  = resourceNewPath

    var jTiled = parseFile(path)

    if "layers" in jTiled:
        for l in jTiled["layers"]:
            if l["type"].str == "imagelayer":
                l.moveImageFile("image")

    if "tilesets" in jTiled:
        let jTileSets = jTiled["tilesets"]
        for jts in jTileSets:
            if "source" in jts:
                let path = jts["source"].str
                let sf = path.splitFile()
                if sf.ext == ".json":
                    let jFile = parseFile(path)
                    readTileSet(jFile, path)
                elif sf.ext == ".tsx":
                    raise newException(Exception, "Incorrect tileSet format by " & path)

                jts.moveTilesetFile("source")
            else:
                readTileSet(jts)

    writeFile(path, $jTiled)

proc main()=
    var inFileName = ""
    for kind, key, val in getopt():
        if kind == cmdArgument:
            inFileName = key
        elif key == "in":
            inFileName = val
        discard

    if inFileName.len > 0:
        readTiledFile(inFileName)

main()
