import json, strutils
import ospaths, os, parseopt2
import xmltree, xmlparser, strtabs

var newSizeX: float
var newSizeY: float

const wrongArgumentsMsg = """
Wrong arguments:
        -file:file_path - path to json tiledmap project
        -size:x,y       - new mapsize
Example:
        -file:tiledmap_test.json -size:32,16
"""

const wrongSize = """
Wrong size representation!

Example:
        -size:32,16 without whitespaces!
"""

proc resizeLayers(layer: JsonNode, ratioX, ratioY: float) =
    for jl in layer["layers"]:
        if "offsetx" in jl:
            let lOffsetx = jl["offsetx"].getFNum()
            jl["offsetx"] = %(lOffsetx * ratioX).int

        if "offsety" in jl:
            let lOffsety = jl["offsety"].getFNum()
            jl["offsety"] = %(lOffsety * ratioY).int

        if "layers" in jl:
            resizeLayers(jl, ratioX, ratioY)
            

proc resizeTiledJsonMap(path: string) =
    var jMap = parseFile(path)

    let oldSizeX = jMap["tilewidth"].getFNum()
    let oldSizeY = jMap["tileheight"].getFNum()

    let ratioX = newSizeX / oldSizeX
    let ratioY = newSizeY / oldSizeY

    resizeLayers(jMap, ratioX, ratioY)

    jMap["tilewidth"] = %newSizeX.int
    jMap["tileheight"] = %newSizeY.int

    var splitFile = path.splitFile()
    let outFilePath = splitFile.dir & '/' & splitFile.name & "_resized_" & $newSizeX & $newSizeY & splitFile.ext

    writeFile(outFilePath, $jMap)

proc resizeTiledTmxMap(path:string)=
    var xMap = loadXml(path)

    let oldSizeX = parseFloat(xMap.attr("tilewidth"))
    let oldSizeY = parseFloat(xMap.attr("tileheight"))

    let ratioX = newSizeX / oldSizeX
    let ratioY = newSizeY / oldSizeY

    for xn in xMap:
        let offx = xn.attr("offsetx")
        let offy = xn.attr("offsety")

        if offx.len > 0:
            let lOffsetx = parseFloat(offx)
            xn.attrs["offsetx"] = $(lOffsetx * ratioX).int

        if offy.len > 0:
            let lOffsety = parseFloat(offy)
            xn.attrs["offsety"] = $(lOffsety * ratioY).int

    block mapTileAttrs:
        xMap.attrs["tilewidth"] = $(newSizeX.int)
        xMap.attrs["tileheight"] = $(newSizeY.int)

    var splitFile = path.splitFile()
    let outFilePath = splitFile.dir & '/' & splitFile.name & "_resized_" & $newSizeX & $newSizeY & splitFile.ext

    writeFile(outFilePath, $xMap)

proc resizeTiledMap(path: string)=
    let splP = path.splitFile()
    if splP.ext == ".json":
        resizeTiledJsonMap(path)
    else:
        resizeTiledTmxMap(path)

proc main()=
    var inFileName = ""
    for kind, key, val in getopt():
        if key == "file":
            inFileName = val

        elif key == "size":
            var splitSize = val.split(',')
            try:
                newSizeX = parseFloat(splitSize[0])
                newSizeY = parseFloat(splitSize[1])
            except:
                echo wrongSize
                quit(1)

        else:
            echo wrongArgumentsMsg
            quit(1)

    if inFileName.len == 0:
        echo wrongArgumentsMsg
        quit(1)

    if newSizeX == 0.0 or newSizeY == 0.0:
        echo wrongArgumentsMsg
        echo wrongSize
        quit(1)

    resizeTiledMap(inFileName)

main()
