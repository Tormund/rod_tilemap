import json, strutils, tables
import ospaths, os, parseopt2

# import tiled_resource_convert
# import tilemap.tile_map

var destinationPath: string
const imageLayersPath = "layers"
const tilesetsPath = "tiles"

var usedGids = newCountTable[int]()
var unusedTiles = newSeq[string]()
var removeUnused = false

type CustomPropertyOwner = enum
    cpoLayer = "layer"
    cpoMap = "map"
    cpoTile = "tile"
    cpoTileSet = "tileset"

type CustomProperty = tuple
    owner: CustomPropertyOwner
    ownerName: string
    key: string
    val: string

var customProps = newSeq[CustomProperty]()

var unusedTileSets = newSeq[string]()

proc moveImageFile(jstr: JsonNode, k: string, pathTo: string) =
    var path = jstr[k].str
    let spFile = splitFile(path)

    var jPath = pathTo & '/' & spFile.name & spFile.ext
    var copyTo = destinationPath & '/' & jPath

    copyTo.normalizePath()

    jstr[k] = %copyTo

    createDir(splitFile(copyTo).dir)
    echo "COPY FILE: IMAGE: ", path, " to ", copyTo, " jpath ", jPath
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

    copyTo.normalizePath()

    jstr[k] = %copyTo

    if pathFrom.len > 0:
        path = pathFrom & '/' & path

    createDir(splitFile(copyTo).dir)
    echo "COPY FILE: TILE: ", path, " to ", copyTo
    copyFile(path, copyTo)

# proc moveTilesetFile(jstr: JsonNode, k: string)=
#     let path = jstr[k].str
#     let spFile = splitFile(path)
#     let jPath = tilesetsPath & '/' & spFile.name & spFile.ext
#     let copyTo = destinationPath & '/' & jPath
#     jstr[k] = %jPath

#     createDir(splitFile(copyTo).dir)
#     echo "COPY FILE: TILESET: ", path, " to ", copyTo
#     copyFile(path, copyTo)

proc extractProperties(jn: JsonNode, owner: CustomPropertyOwner, name: string):seq[CustomProperty]=
    if "propertytypes" notin jn: return
    result = @[]
    for key, ptype in jn["propertytypes"]:

        # echo "\nSTART EXTRACT ", key, " va ", ptype.str
        var cp: CustomProperty
        cp.owner = owner
        cp.ownerName = name
        # cp.ptype = parseEnum[PropertyType](ptype.str)
        cp.key = key
        cp.val = $jn["properties"][key]

        # echo "EXTRACT PROPERTY ", cp
        # echo ""
        result.add(cp)

    jn.delete("propertytypes")
    jn.delete("properties")


proc writeProperties(jn: JsonNode, customProps: seq[CustomProperty])=
    if customProps.len == 0: return

    var propNames = newJArray()
    var propValues = newJArray()

    for cp in customProps:
        propNames.add(%cp.key)
        propValues.add(%cp.val)

    jn["customPropertyNames"]  = propNames
    jn["customPropertyValues"] = propValues

proc readTileSet(jn: JsonNode, firstgid: int, pathFrom: string = "")=
    let spFile = splitFile(pathFrom)
    let tdest = jn["name"].str
    let integrated = true

    # let destPath = destinationPath & '/' & tilesetsPath & '/' & spFile.name & ".json"
    var isTileSetUsed = true

    if "image" in jn:
        try:
            jn.moveTileFile("image", spFile.dir, tdest, integrated)
        except OSError:
            when not defined(safeMode):
                raise

    elif "tiles" in jn:
        if removeUnused:
            var tiles = newJObject()
            for k, v in jn["tiles"]:
                let gid = k.parseInt() + firstgid
                if  gid in usedGids:
                    try:
                        v.moveTileFile("image", spFile.dir, tdest, integrated)
                        tiles[k] = v

                    except OSError:
                        when not defined(safeMode):
                            raise
                else:
                    unusedTiles.add(v["image"].str)

            jn["tiles"] = tiles
            if tiles.len == 0:
                isTileSetUsed = false
        else:
            for k, v in jn["tiles"]:
                let gid = k.parseInt() + firstgid
                if gid notin usedGids:
                    unusedTiles.add(v["image"].str)

                try:
                    v.moveTileFile("image", spFile.dir, tdest, integrated)
                except OSError:
                    when not defined(safeMode):
                        raise

    if isTileSetUsed:
        if "tiles" in jn and "tilepropertytypes" in jn and "tileproperties" in jn:
            var propOwner = newJArray()
            var propNames = newJArray()
            var propValues = newJArray()

            for key, ptype in jn["tilepropertytypes"]:
                var tileProps = newSeq[CustomProperty]()
                for name, value in jn["tileproperties"][key]:
                    var cp: CustomProperty
                    cp.ownerName = key
                    cp.key = name
                    cp.val = $value

                    tileProps.add(cp)

                if tileProps.len > 0:
                    for cp in tileProps:
                        propOwner.add(%cp.ownerName)
                        propNames.add(%cp.key)
                        propValues.add(%cp.val)
                    # echo ""

            jn.delete("tilepropertytypes")
            jn.delete("tileproperties")

            jn["customTilePropertyNames"] = propNames
            jn["customTilePropertyValues"] = propValues
            jn["customTilePropertyOwner"] = propOwner

        jn.writeProperties extractProperties(jn, cpoTileSet, tdest)
        # jn.writeProperties(props)

    else:
        unusedTileSets.add(pathFrom)

proc prepareLayers(jNode: var JsonNode, width, height: int) =
    var layers = newJArray()
    var nodeLayers = jNode["layers"]

    for layer in nodeLayers.mitems():
        if "properties" in layer:
            if "tiledonly" in layer["properties"]:
                if layer["properties"]["tiledonly"].getBool():
                    continue
            else:
                layer.writeProperties(extractProperties(layer, cpoLayer, layer["name"].str))


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

            for y in 0 ..< height:
                for x in 0 ..< width:
                    let off = y * width + x
                    if data[off] != 0:
                        usedGids.inc(data[off], 1)

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


proc readTiledFile(path: string): string =
    let tmpSplit = path.splitFile()
    var jTiled = parseFile(path)
    var width = jTiled["width"].getInt()
    var height = jTiled["height"].getInt()

    if "layers" in jTiled:
        prepareLayers(jTiled, width, height)

    if "tilesets" in jTiled:
        var jTileSets = jTiled["tilesets"]
        var tmpTileSets = newJArray()
        for jts in jTileSets:
            if "source" in jts:
                let originalPath = jts["source"].str
                let sf = originalPath.splitFile()

                if sf.ext == ".json":
                    let jFile = parseFile(originalPath)
                    try:
                        var firstgid = 0
                        if "firstgid" in jts:
                            firstgid = jts["firstgid"].num.int

                        readTileSet(jFile, firstgid, originalPath)
                        jFile["firstgid"] = %firstgid
                        if removeUnused:
                            if originalPath notin unusedTileSets:
                                tmpTileSets.add(jFile)
                            else:
                                echo "\nUNUSED TILESET ", originalPath
                    except OSError:
                        when not defined(safeMode):
                            raise

                elif sf.ext == ".tsx":
                    when not defined(safeMode):
                        raise newException(Exception, "Incorrect tileSet format by " & originalPath)

            else:
                var firstgid = 0
                if "firstgid" in jts:
                    firstgid = jts["firstgid"].num.int
                readTileSet(jts, firstgid)
                tmpTileSets.add(jts)

        jTiled["tilesets"] = tmpTileSets

    jTiled.writeProperties(extractProperties(jTiled, cpoMap, "map"))

    result = destinationPath & "/" & tmpSplit.name & ".jcomp"
    writeFile(result, $jTiled)

import tiled_resource_convert

proc main()=
    var inFileName = ""
    for kind, key, val in getopt():
        if key == "map":
            inFileName = val
        elif key == "dest":
            destinationPath = val
        elif key == "opt":
            removeUnused = parseBool(val)

    echo "tiled_resource_collect inFileName ", inFileName, " destinationPath ", destinationPath
    if inFileName.len > 0:
        when defined(safeMode):
            echo "\n\n Running in safeMode !!\n\n"

        let outFile =  readTiledFile(inFileName)
        echo "tiled_resource_collected inFileName ", inFileName, " destinationPath ", destinationPath
        echo "converting in rod format"
        convertInRodAsset(outFile, outFile)
        echo "convertation done"

        # echo "\n\n usedGids "
        # for k, v in usedGids:
        #     echo "gid: ", k, " used: ", v
        # # usedGids
        # echo "\n\n unused tiles ", unusedTiles

main()
