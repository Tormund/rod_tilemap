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


    createDir(currentLocation & '/' & resourceNewPath)

    when defined(safeMode):
        try:
            copyFile(path, copyTo)
        except:
            echo "Image not found: from ", path, " to ", copyTo
    else:
        echo "COPY FILE: ", path
        copyFile(path, copyTo)

proc moveTilesetFile(jstr: JsonNode, k: string)=
    let path = jstr[k].str
    let spFile = splitFile(path)
    let jPath = tilesetNewPath & '/' & spFile.name & spFile.ext
    let copyTo = currentLocation & '/' & jPath
    jstr[k] = %jPath


    createDir(currentLocation & '/' & tilesetNewPath)
    when defined(safeMode):
        try:
            copyFile(path, copyTo)
        except:
            echo "tileset not found from ", path, " to ", copyTo
    else:
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


proc prepareLayers(jNode: var JsonNode, width, height: int) =
    var layers = newJArray()
    var nodeLayers = jNode["layers"]

    # var isStaggered = jNode["orientation"].str == "staggered"
    # var staggeredAxisX: bool
    # var isStaggerIndexOdd: bool
    # if isStaggered:
    #     staggeredAxisX = jNode["staggeraxis"].str == "x"
    #     isStaggerIndexOdd = jNode["staggerindex"].getStr() == "odd"

    for layer in nodeLayers.mitems():
        if layer["type"].str == "group" and "layers" in layer:
            prepareLayers(layer, width, height)
            layers.add(layer)
            continue

        if layer["type"].str == "imagelayer":
            if "image" in layer and layer["image"].str.len > 0:
                try:
                    layer.moveImageFile("image")
                    layers.add(layer)
                except OSError:
                    echo "Image has not been founded. Skip."
                    continue

        if "data" in layer:
            let jdata = layer["data"]
            var data = newSeq[int]()

            for jd in jdata:
                data.add(jd.num.int)

            var minX = width - 1
            var minY = height - 1
            var maxX = 0
            var maxY = 0

            # for i in 0 ..< data.len:
            #     var x = i mod width
            #     var y = i div height

            for y in 0 ..< height:
                for x in 0 ..< width:
                # if isStaggered:
                #     if staggeredAxisX:

                    let off = y * width + x
                    if data[off] != 0:
                        if x > maxX: maxX = x
                        if x < minX: minX = x
                        if y > maxY: maxY = y
                        if y < minY: minY = y

            var allDataEmpty = minY == height - 1 and minX == width - 1

            var newData = newJArray()
            if not allDataEmpty:
                layers.add(layer)
                for y in minY .. maxY:
                    for x in minX .. maxX:
                        let off = (y * width + x)
                        newData.add(%data[off])
                        data[off] = 0

                for i, d in data:
                    if d != 0:
                        raise newException(Exception, "Optimization failed")

                var actualSize = newJObject()
                actualSize["minX"] = %minX
                actualSize["maxX"] = %(maxX + 1)
                actualSize["minY"] = %minY
                actualSize["maxY"] = %(maxY + 1)
                layer["actualSize"] = actualSize

            layer["data"] = newData

    echo "PREPARED ", layers.len

    jNode["layers"] = layers


proc readTiledFile(path: string)=
    let tmpSplit = path.splitFile()
    currentLocation = tmpSplit.dir
    resourceNewPath = "assets"
    tilesetNewPath  = resourceNewPath

    var jTiled = parseFile(path)
    var width = jTiled["width"].getNum().int
    var height = jTiled["height"].getNum().int

    if "layers" in jTiled:
        prepareLayers(jTiled, width, height)

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
                    when not defined(safeMode):
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
        when defined(safeMode):
            echo "\n\n Running in safeMode !!\n\n"

        readTiledFile(inFileName)

main()
