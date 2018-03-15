import json, os, tables, strutils, logging

import rod.node
import rod.component
import rod.tools.serializer
import rod.rod_types
import rod.utils.json_serializer

import nimx.matrixes
import nimx.types
import nimx.image
import tilemap.tile_map
import hashes

proc parseTileMap(tm: TileMap, jtm: JsonNode)

proc convertInRodAsset*(inPath: string, outPath: string)=
    let tmpSplit = inPath.splitFile()
    var raw = parseFile(inPath)
    var node = newNode(tmpSplit.name)
    var tm = node.component(TileMap)
    var jss = newJsonSerializer()

    tm.parseTileMap(raw)
    node.serialize(jss)

    writeFile(outPath, jss.node.pretty())

const rawParsingBlock = true
when rawParsingBlock:
    var tiledLayerCreators = initTable[string, proc(tm: TileMap, jl: JsonNode): BaseTileMapLayer]()

    tiledLayerCreators["imagelayer"] = proc(tm: TileMap, jl: JsonNode): BaseTileMapLayer =
        let layer = new(ImageMapLayer)
        if "image" in jl and jl["image"].str.len > 0:
            var imgPath = jl["image"].str
            var img = new(SelfContainedImage)
            img.setFilePath(imgPath)
            layer.image = img
        result = layer

    tiledLayerCreators["tilelayer"] = proc(tm: TileMap, jl: JsonNode): BaseTileMapLayer =
        let layer = new(TileMapLayer)

        var dataSize = (tm.mapSize.width * tm.mapSize.height).int
        if "actualSize" in jl:
            let acts = jl["actualSize"]
            layer.actualSize.minx = acts["minX"].getNum().int32
            layer.actualSize.maxx = acts["maxX"].getNum().int32
            layer.actualSize.miny = acts["minY"].getNum().int32
            layer.actualSize.maxy = acts["maxY"].getNum().int32

            dataSize = (layer.actualSize.maxx - layer.actualSize.minx) * (layer.actualSize.maxy - layer.actualSize.miny)

        else:
            layer.actualSize.minx = 0
            layer.actualSize.maxx = tm.mapSize.width.int32
            layer.actualSize.miny = 0
            layer.actualSize.maxy = tm.mapSize.height.int32

        layer.data = newSeq[int16](dataSize)

        var i = 0
        for jld in jl["data"]:
            layer.data[i] = jld.getNum().int16
            inc i

        result = layer

    proc getProperties(jn: JsonNode):Properties=
        if "customPropertyNames" in jn and "customPropertyValues" in jn:
            result = newTable[string, JsonNode]()
            var names = jn["customPropertyNames"]
            var vals = jn["customPropertyValues"]

            var index = 0
            for jname in names:
                result[jname.str] = parseJson(vals[index].str)
                inc index

    proc getTileProperties(jn: JsonNode, id: int):Properties=
        if "customTilePropertyNames" in jn and "customTilePropertyValues" in jn and "customTilePropertyOwner" in jn:

            var names = jn["customTilePropertyNames"]
            var vals = jn["customTilePropertyValues"]
            var owners = jn["customTilePropertyOwner"]

            var index = 0
            for owner in owners:
                let ownid = parseInt(owner.str)
                if ownid == id:
                    if result.isNil:
                        result = newTable[string, JsonNode]()
                    var jname = names[index].str
                    result[jname] = parseJson(vals[index].str)
                inc index

    proc parseTileMap(tm: TileMap, jtm: JsonNode) =
        var mapProps = getProperties(jtm)
        if not mapProps.isNil:
            tm.properties = mapProps
        if "orientation" in jtm:
            try:
                tm.orientation = parseEnum[TileMapOrientation](jtm["orientation"].getStr())
            except:
                if jtm["orientation"].getStr() == "staggered":
                    let isStaggerAxisX = jtm["staggeraxis"].getStr() == "x"
                    if isStaggerAxisX:
                        tm.orientation = TileMapOrientation.staggeredX
                    else:
                        tm.orientation = TileMapOrientation.staggeredY
                    tm.isStaggerIndexOdd = jtm["staggerindex"].getStr() == "odd"

        if "width" in jtm and "height" in jtm:
            tm.mapSize = newSize(jtm["width"].getFNum(), jtm["height"].getFNum())

        if "tileheight" in jtm and "tilewidth" in jtm:
            let tWidth = jtm["tilewidth"].getNum().float
            let tHeigth = jtm["tileheight"].getNum().float
            tm.tileSize = newVector3(tWidth, tHeigth)

        if "layers" in jtm:
            tm.layers = @[]

            proc parseLayer(tm: TileMap, jl: JsonNode, pos: Vector3 = newVector3(), visible = true, parentProperties: Properties = nil)=
                let layerType = jl["type"].getStr()
                let layerCreator = tiledLayerCreators.getOrDefault(layerType)

                var position = newVector3()
                if "offsetx" in jl:
                    position.x = jl["offsetx"].getFNum()
                if "offsety" in jl:
                    position.y = jl["offsety"].getFNum()

                position += pos

                let enabled = if visible: jl["visible"].getBVal() else: false

                var layProps = getProperties(jl)

                if layerCreator.isNil:
                    if layerType == "group":
                        if not layProps.isNil and not parentProperties.isNil:
                            for k, v in parentProperties:
                                if k notin layProps:
                                    layProps[k] = v
                        elif layProps.isNil and not parentProperties.isNil:
                            layProps = parentProperties

                        for jLayer in jl["layers"]:
                            tm.parseLayer(jLayer, position, enabled, layProps)
                    else:
                        warn "TileMap loadTiled: ", layerType, " doesn't supported!"
                    return

                var layer = tm.layerCreator(jl)
                layer.map = tm
                let name = jl["name"].getStr()

                if not layProps.isNil:
                    layer.properties = layProps
                    if not parentProperties.isNil:
                        for k, v in parentProperties:
                            if k notin layer.properties:
                                layer.properties[k] = v


                let alpha = jl["opacity"].getFNum()

                if "width" notin jl or "height" notin jl:
                    layer.size = zeroSize
                else:
                    layer.size = newSize(jl["width"].getFNum(), jl["height"].getFNum())

                layer.offset = newSize(position.x, position.y)

                var layerNode = newNode(name)
                layerNode.position = position
                layerNode.alpha = alpha
                layerNode.enabled = enabled

                if layerType == "imagelayer":
                    layerNode.setComponent("ImageMapLayer", layer)
                elif layerType == "tilelayer":
                    layerNode.setComponent("TileMapLayer", layer)

                layer.node = layerNode
                tm.node.addChild(layerNode)
                tm.layers.add(layer)

            for jl in jtm["layers"]:
                tm.parseLayer(jl)

        if "tilesets" in jtm:
            var tileSets = jtm["tilesets"]
            tm.tileSets = @[]
            for jts in tileSets:
                var ts:BaseTileSet
                if "image" in jts:
                    var sts = new(TileSheet)
                    var img = new(SelfContainedImage)
                    img.setFilePath(jts["image"].str)
                    sts.sheet = img
                    sts.columns = jts["columns"].getNum().int
                    ts = sts
                else:
                    var cts = new(TileCollection)
                    cts.collection = @[]
                    for k, v in jts["tiles"]:
                        var id = k.parseInt()
                        var img = new(SelfContainedImage)
                        img.setFilePath(v["image"].str)
                        if id >= cts.collection.len:
                            cts.collection.setLen(id + 1)
                        cts.collection[id] = (image: img, properties: getTileProperties(jts, id))
                    ts = cts

                var tilesetProps = jts.getProperties()
                if not tilesetProps.isNil:
                    ts.properties = tilesetProps

                if "firstgid" in jts:
                    ts.firstgid = jts["firstgid"].getNum().int32
                if "tilecount" in jts:
                    ts.tilesCount = jts["tilecount"].getNum().int32
                if "name" in jts:
                    ts.name = jts["name"].str
                if "tilewidth" in jts:
                    ts.tileSize = newVector3(jts["tilewidth"].getFNum(), jts["tileheight"].getFNum())

                tm.tileSets.add(ts)

when isMainModule:
    convertInRodAsset("map.json", "out_map.json")