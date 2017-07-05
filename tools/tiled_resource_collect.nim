import json, strutils
import ospaths, os, parseopt2

var destinationPath: string
const imageLayersPath = "layers"
const tilesetsPath = "../tiles"

proc moveImageFile(jstr: JsonNode, k: string, pathTo: string) =
    var path = jstr[k].str
    let spFile = splitFile(path)

    var jPath = pathTo & '/' & spFile.name & spFile.ext    
    let copyTo = destinationPath & '/' & jPath

    jstr[k] = %jPath

    createDir(splitFile(copyTo).dir)
    echo "COPY FILE: IMAGE: ", path, " to ", copyTo
    copyFile(path, copyTo)

proc moveTileFile(jstr: JsonNode, k: string, pathFrom: string = "", pathTo: string = "", integrated: bool) =
    var path = jstr[k].str
    let spFile = splitFile(path)
    
    var jPath = tilesetsPath & '/'
    if integrated:
        jPath &= pathTo & '/' & spFile.name & spFile.ext
    else:
        jPath = pathTo & '/' & spFile.name & spFile.ext

    var copyTo = destinationPath & '/'
    if integrated:
        copyTo &= jPath
    else:
        copyTo &= tilesetsPath & '/' & jPath

    jstr[k] = %jPath
    
    if pathFrom.len > 0:
        path = pathFrom & '/' & path
    
    createDir(splitFile(copyTo).dir)
    echo "COPY FILE: TILE: ", path, " to ", copyTo
    copyFile(path, copyTo)

proc moveTilesetFile(jstr: JsonNode, k: string)=
    let path = jstr[k].str
    let spFile = splitFile(path)
    let jPath = tilesetsPath & '/' & spFile.name & spFile.ext
    let copyTo = destinationPath & '/' & jPath
    jstr[k] = %jPath

    createDir(splitFile(copyTo).dir)
    echo "COPY FILE: TILESET: ", path, " to ", copyTo
    copyFile(path, copyTo)

proc readTileSet(jn: JsonNode, pathFrom: string = nil)=
    let spFile = splitFile(pathFrom)
    let tdest = jn["name"].str
    let integrated = pathFrom.isNil
    
    if "image" in jn:
        try:
            jn.moveTileFile("image", spFile.dir, tdest, integrated)
        except OSError:
            when not defined(safeMode):
                raise

    elif "tiles" in jn:
        for k, v in jn["tiles"]:
            try:
                v.moveTileFile("image", spFile.dir, tdest, integrated)
            except OSError:
                when not defined(safeMode):
                    raise

    if not integrated:
        writeFile(destinationPath & '/' & tilesetsPath & '/' & spFile.name & ".json", $jn)

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
        if "properties" in layer:
            if "tiledonly" in layer["properties"]:
                if layer["properties"]["tiledonly"].getBVal():
                    continue

        if layer["type"].str == "group" and "layers" in layer:
            prepareLayers(layer, width, height)
            layers.add(layer)
            continue

        if layer["type"].str == "imagelayer":
            if "image" in layer and layer["image"].str.len > 0:
                try:
                    layer.moveImageFile("image", imageLayersPath)
                    layers.add(layer)
                except OSError:
                    when not defined(safeMode):
                        raise
                    else:
                        echo "Image has not been founded. Skip layer."
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
    jNode["layers"] = layers


proc readTiledFile(path: string)=
    let tmpSplit = path.splitFile()
    var jTiled = parseFile(path)
    var width = jTiled["width"].getNum().int
    var height = jTiled["height"].getNum().int

    if "layers" in jTiled:
        prepareLayers(jTiled, width, height)

    if "tilesets" in jTiled:
        let jTileSets = jTiled["tilesets"]
        for jts in jTileSets:
            if "source" in jts:
                let originalPath = jts["source"].str
                let sf = originalPath.splitFile()

                if sf.ext == ".json":
                    let jFile = parseFile(originalPath)
                    try:
                        jts.moveTilesetFile("source")
                        readTileSet(jFile, originalPath)
                    except OSError:
                        when not defined(safeMode):
                            raise

                elif sf.ext == ".tsx":
                    when not defined(safeMode):
                        raise newException(Exception, "Incorrect tileSet format by " & originalPath)

            else:
                readTileSet(jts)

    writeFile(destinationPath & "/" & tmpSplit.name & tmpSplit.ext, $jTiled)

proc main()=
    var inFileName = ""
    for kind, key, val in getopt():
        if key == "map":
            inFileName = val
        elif key == "dest":
            destinationPath = val
        discard
    echo "tiled_resource_collect inFileName ", inFileName, " destinationPath ", destinationPath
    if inFileName.len > 0:
        when defined(safeMode):
            echo "\n\n Running in safeMode !!\n\n"

        readTiledFile(inFileName)

main()
