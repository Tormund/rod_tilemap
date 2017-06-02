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

    echo "map width ", width, " height ", height
    var optimizedTiles = 0
    var totalDefaultDataLen = 0
    if "layers" in jTiled:
        for l in jTiled["layers"]:
            if l["type"].str == "imagelayer":
                l.moveImageFile("image")

            if "data" in l:
                let jdata = l["data"]
                var data = newSeq[int]()

                for jd in jdata:
                    data.add(jd.num.int)

                var cols = 0
                var cole = width
                var rows = 0
                var rowe = height

                var topDone = false
                while not topDone:
                    var colSum = 0
                    for col in 0 .. width:
                        let i = col + rows * width
                        if i < data.len:
                            colSum += data[i]
                        else:
                            echo "colTop index ", i

                    if colSum != 0:
                        topDone = true
                    else:
                        inc rows
                        topDone = rows == rowe

                var bottomDone = false
                while not bottomDone:
                    var colSum = 0
                    for col in 0 .. width:
                        let i = col + (rowe - 1) * width
                        if i < data.len and i >= 0:
                            colSum += data[i]
                        else:
                            echo "colBot index ", i
                    if colSum != 0:
                        bottomDone = true
                    else:
                        dec rowe
                        bottomDone = rows >= rowe

                var leftDone = false
                while not leftDone:
                    var rowSum = 0
                    for row in 0 .. height:
                        let i = row * height + cols
                        if i < data.len:
                            rowSum += data[i]
                        else:
                            echo "rowLeft index ", i, " ", cols

                    if rowSum != 0:
                        leftDone = true
                    else:
                        inc cols
                        leftDone = cols == cole

                var rightDone = false
                while not rightDone:
                    var rowSum = 0
                    for row in 0 .. height:
                        let i = row * height + (cole - 1)
                        if i >= 0 and i < data.len:
                            rowSum += data[i]
                        else:
                            echo "rowRight i ", i

                    if rowSum != 0:
                        rightDone = true
                    else:
                        dec cole
                        rightDone = cols >= cole

                var newData = newJArray()
                for x in cols ..< cole:
                    for y in rows ..< rowe:
                        let i = width * y + x
                        newData.add(%data[i])
                        data[i] = 0

                for i, d in data:
                    if d != 0:
                        echo "checkFailed !!! at x ", i mod width, " y ", i div width, " cols ", cols, " cole ", cole , " rows ", rows, " rowe ", rowe

                totalDefaultDataLen += jdata.len
                optimizedTiles += jdata.len - newData.len
                l["data"] = newData
                # l["cutDataFront"] = %cutFront
                # l["cutDataBack"] = %cutBack

    echo "optimized ", optimizedTiles, " ", totalDefaultDataLen , " % ", optimizedTiles / totalDefaultDataLen

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

    # writeFile(path, $jTiled)

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
