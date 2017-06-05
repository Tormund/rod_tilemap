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

proc readTiledFile(path: string)=
    let tmpSplit = path.splitFile()
    currentLocation = tmpSplit.dir
    resourceNewPath = "assets"
    tilesetNewPath  = resourceNewPath

    var jTiled = parseFile(path)
    let width = jTiled["width"].getNum().int
    let height = jTiled["height"].getNum().int

    if "layers" in jTiled:
        var layers = newJArray()
        for l in jTiled["layers"]:
            if l["type"].str == "imagelayer":
                if "image" in l and l["image"].str.len > 0:
                    layers.add(l)
                    l.moveImageFile("image")

            if "data" in l:
                let jdata = l["data"]
                var data = newSeq[int]()

                for jd in jdata:
                    data.add(jd.num.int)

                var minX = width - 1
                var minY = height - 1
                var maxX = 0
                var maxY = 0

                for x in 0 ..< width:
                    for y in 0 ..< height:
                        let off = (y * width + x)
                        if data[off].uint8 != 0:
                            if x > maxX: maxX = x
                            if x < minX: minX = x
                            if y > maxY: maxY = y
                            if y < minY: minY = y

                var allDataEmpty = minY == height - 1 and minX == width - 1

                var newData = newJArray()
                if not allDataEmpty:
                    layers.add(l)
                    for x in minX .. maxX:
                        for y in minY .. maxY:
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
                    l["actualSize"] = actualSize

                l["data"] = newData



        jTiled["layers"] = layers

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
