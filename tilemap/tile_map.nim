import rod / [ component, node ]
import rod / tools / [ serializer, debug_draw ]
import nimx / [ types, property_visitor, matrixes, portable_gl, context, image, resource,
                render_to_image ]

import json, tables, strutils, logging
import opengl

type
    BaseTileMapLayer = ref object of RootObj
        size: Size
        name*: string
        enabled*: bool
        position*: Vector3
        alpha*: float

    TileMapLayer* = ref object of BaseTileMapLayer
        data*: seq[int]
        batchImage: SelfContainedImage
        isDirty: bool

    ImageMapLayer* = ref object of BaseTileMapLayer
        image*: SelfContainedImage

    BaseTileSet = ref object of RootObj
        tileSize: Vector3
        firstGid: int
        tilesCount: int
        name: string

    TileSheet = ref object of BaseTileSet
        sheet: SelfContainedImage
        columns: int

    TileCollection = ref object of BaseTileSet
        collection: Table[int, SelfContainedImage]

    TileMapOrientation* {.pure.}= enum
        orthogonal
        isometric
        staggered
        hexagonal

    TileMap* = ref object of Component
        mapSize*: Size
        tileSize*: Vector3
        layers: seq[BaseTileMapLayer]
        tileSets: seq[BaseTileSet]
        case orientation*: TileMapOrientation
        of TileMapOrientation.staggered:
            isStaggerAxisX: bool
            isStaggerIndexOdd: bool
        else: discard

method canDrawTile(ts: BaseTileSet, tid: int): bool=
    result = tid >= ts.firstGid and tid < ts.firstGid + ts.tilesCount

method canDrawTile(ts: TileCollection, tid: int): bool=
    result = not ts.collection.getOrDefault(tid).isNil

method drawTile(ts: BaseTileSet, tid: int, r: Rect, a: float) {.base.}=
    raise newException(Exception, "Abstract method called!")

method drawTile(ts: TileSheet, tid: int, r: Rect, a: float)=
    let tilePos = tid - ts.firstGid
    let tileX = (tilePos mod ts.columns) * ts.tileSize.x.int
    let tileY = (tilePos div ts.columns) * ts.tileSize.y.int
    currentContext().drawImage(ts.sheet, r, newRect(tileX.float, tileY.float, ts.tileSize.x, ts.tileSize.y), a)

method drawTile(ts: TileCollection, tid: int, r: Rect, a: float)=
    let image = ts.collection[tid]
    let imageSize = image.size
    var tr = r
    if imageSize.width.int != tr.width.int or imageSize.height.int != tr.height.int:
        tr.origin += newPoint(0, r.size.height - imageSize.height)
        tr.size = imageSize
    # echo "drawTile ", tid, " ", imageSize, " rects ", @[fr, tr]
    currentContext().drawImage(image, tr, alpha = a)

proc debugDraw(tm: TileMap, layer: TileMapLayer) =
    let gl = currentContext().gl
    gl.disable(gl.DEPTH_TEST)

    case tm.orientation
    of TileMapOrientation.orthogonal:
        for x in 0 .. tm.mapSize.width.int:
            let
                fp = newVector3(x.float * tm.tileSize.x, 0.0) + layer.position
                tp = newVector3(x.float * tm.tileSize.x, tm.tileSize.y * tm.mapSize.height) + layer.position

            DDdrawLine(fp, tp)

        for y in 0 .. tm.mapSize.height.int:
            let
                fp = newVector3(0.0, y.float * tm.tileSize.y) + layer.position
                tp = newVector3(tm.tileSize.x * tm.mapSize.height, y.float * tm.tileSize.y) + layer.position

            DDdrawLine(fp, tp)

    of TileMapOrientation.isometric:
        let firstTilePosX = (tm.mapSize.height) * tm.tileSize.x * 0.5

        for i in 0 .. tm.mapSize.width.int:
            var x = (i.float * tm.tileSize.x * 0.5) - (0.0 * tm.tileSize.x * 0.5) + firstTilePosX
            var y = (0.0 * tm.tileSize.y * 0.5) + (i.float * tm.tileSize.y * 0.5)
            let fp = newVector3(x, y) + layer.position

            x = (i.float * tm.tileSize.x * 0.5) - (tm.mapSize.height * tm.tileSize.x * 0.5) + firstTilePosX
            y = (tm.mapSize.height * tm.tileSize.y * 0.5) + (i.float * tm.tileSize.y * 0.5)
            let tp = newVector3(x, y) + layer.position

            DDdrawLine(fp, tp)

        for i in 0 .. tm.mapSize.height.int:
            var x = (0.0 * tm.tileSize.x * 0.5) - (i.float * tm.tileSize.x * 0.5) + firstTilePosX
            var y = (i.float * tm.tileSize.y * 0.5) + (0.0 * tm.tileSize.y * 0.5)
            let fp = newVector3(x, y) + layer.position

            x = (tm.mapSize.width * tm.tileSize.x * 0.5) - (i.float * tm.tileSize.x * 0.5) + firstTilePosX
            y = (i.float * tm.tileSize.y * 0.5) + (tm.mapSize.width * tm.tileSize.y * 0.5)
            let tp = newVector3(x, y) + layer.position

            DDdrawLine(fp, tp)

    else: discard

    gl.disable(gl.DEPTH_TEST)

proc layerRect(tm: TileMap, l: TileMapLayer): Rect=
    case tm.orientation:
    of TileMapOrientation.orthogonal:
        result = newRect(l.position.x, l.position.y, tm.mapSize.width * tm.tileSize.x, tm.mapSize.height * tm.tileSize.y)
    of TileMapOrientation.isometric:
        let
            width = (tm.mapSize.width + tm.mapSize.height) * tm.tileSize.x * 0.5
            height = (tm.mapSize.width + tm.mapSize.height) * tm.tileSize.y * 0.5
        result = newRect(l.position.x, l.position.y, width, height)

    of TileMapOrientation.staggered:
        result.origin = newPoint(l.position.x, l.position.y)
        var width, height : float
        if tm.isStaggerAxisX:
            width = tm.tileSize.x * (tm.mapSize.width / 2.0 + 0.5)
            height = tm.tileSize.y * (tm.mapSize.height + 0.5)
        else:
            width = tm.tileSize.x * (tm.mapSize.width + 0.5)
            height = tm.tileSize.y * (tm.mapSize.height / 2.0 + 0.5)

        result.size = newSize(width, height)

    else:
        discard

proc tileDrawRect(tm: TileMap, pos:int): Rect=
    var x = 0.0
    var y = 0.0

    var col = pos div tm.mapSize.width.int
    var row = pos mod tm.mapSize.width.int

    case tm.orientation:
    of TileMapOrientation.orthogonal:
        x = row.float * tm.tileSize.x
        y = col.float * tm.tileSize.y

    of TileMapOrientation.isometric:
        let firstTilePosX = (tm.mapSize.height - 1.0) * tm.tileSize.x * 0.5
        x = (row.float * tm.tileSize.x * 0.5) - (col.float * tm.tileSize.x * 0.5)
        y = (col.float * tm.tileSize.y * 0.5) + (row.float * tm.tileSize.y * 0.5)
        x += firstTilePosX

    of TileMapOrientation.staggered:
        let offIndex = if tm.isStaggerIndexOdd: 0 else: 1

        if tm.isStaggerAxisX:
            let axisP = (row + offIndex) mod 2
            x = row.float * tm.tileSize.x * 0.5
            y = col.float * tm.tileSize.y + axisP.float * 0.5 * tm.tileSize.y
        else:
            let axisP = (col + offIndex) mod 2
            x = row.float * tm.tileSize.x + axisP.float * tm.tileSize.x * 0.5
            y = col.float * tm.tileSize.y * 0.5

    of TileMapOrientation.hexagonal:
        x = row.float * tm.tileSize.x
        y = col.float * tm.tileSize.y
    else:
        discard

    result.origin.x = x
    result.origin.y = y
    result.size.width = tm.tileSize.x
    result.size.height = tm.tileSize.y

method drawLayer(layer: BaseTileMapLayer, tm: TileMap) {.base.} =
    raise newException(Exception, "Abstract method called!")

method drawLayer(layer: ImageMapLayer, tm: TileMap)=
    currentContext().drawImage(layer.image, newRect(layer.position.x, layer.position.y, layer.image.size.width, layer.image.size.height), alpha = layer.alpha)

method drawLayer(layer: TileMapLayer, tm: TileMap)=
    var r = tm.layerRect(layer)

    if layer.batchImage.isNil:
        layer.batchImage = imageWithSize(r.size)
        layer.isDirty = true

    if layer.isDirty and layer.enabled:
        layer.batchImage.draw() do():
            for pos, tileId in layer.data: # todo iterate only tiles in viewport with some offset
                if tileId == 0: continue
                let tr = tm.tileDrawRect(pos)

                for tileSet in tm.tileSets:
                    if tileSet.canDrawTile(tileId):
                        tileSet.drawTile(tileId, tr, layer.alpha)
                        break

            layer.isDirty = false

    currentContext().drawImage(layer.batchImage, r)

    if tm.node.sceneView.editing:
        tm.debugDraw(layer)

method draw*(tm: TileMap) =
    for layer in tm.layers:
        if layer.enabled:
            layer.drawLayer(tm)

#todo: serialize support
# method deserialize*(c: TileMap, j: JsonNode, serealizer: Serializer) =
#     discard

# method serialize*(c: TileMap, s: Serializer): JsonNode=
#     result = newJObject()

method visitProperties*(tm: TileMap, p: var PropertyVisitor) =
    p.visitProperty("mapSize", tm.mapSize)
    p.visitProperty("tileSize", tm.tileSize)

registerComponent(TileMap, "TileMap")

#[
    Tiled support http://www.mapeditor.org/
 ]#

var tiledLayerCreators = initTable[string, proc(typeName: string, jl: JsonNode): BaseTileMapLayer]()

tiledLayerCreators["imagelayer"] = proc(typeName: string, jl: JsonNode): BaseTileMapLayer=
    let layer = new(ImageMapLayer)
    if "image" in jl:
        layer.image = imageWithResource(jl["image"].getStr())
    result = layer

tiledLayerCreators["tilelayer"] = proc(typeName: string, jl: JsonNode): BaseTileMapLayer=
    let layer = new(TileMapLayer)
    layer.data = @[]
    for jld in jl["data"]:
        layer.data.add(jld.getNum().int)

    layer.isDirty = true

    result = layer

proc loadTileSet(jTileSet: JsonNode): BaseTileSet=
    var firstgid = 0

    if "firstgid" in jTileSet:
        firstgid = jTileSet["firstgid"].getNum().int

    if "tiles" in jTileSet:
        let tileCollection = new(TileCollection)

        tileCollection.tilesCount = jTileSet["tilecount"].getNum().int
        tileCollection.collection = initTable[int, SelfContainedImage]()
        var tilesFound = 0
        var i = 1
        while tilesFound < tileCollection.tilesCount:
            let k = $i
            if k in jTileSet["tiles"]:
                inc tilesFound
                let tilePath = jTileSet["tiles"][k]["image"].getStr()
                tileCollection.collection[i + firstgid] = imageWithResource(tilePath)
                echo "register tileid ", i + firstgid, " with path ", tilePath
            inc i

        result = tileCollection

    elif "image" in jTileSet:
        let tileSheet = new(TileSheet)
        tileSheet.sheet = imageWithResource(jTileSet["image"].getStr())
        tileSheet.columns = jTileSet["columns"].getNum().int
        result = tileSheet

    elif "source" in jTileSet:
        let jts = parseFile(pathForResource(jTileSet["source"].getStr()))
        result = loadTileSet(jts)
        result.firstGid = jTileSet["firstgid"].getNum().int
        return
    else:
        raise newException(Exception, "Incorrect tileSet format")

    result.name = jTileSet["name"].getStr()
    result.tileSize = newVector3(jTileSet["tilewidth"].getFNum(), jTileSet["tileheight"].getFNum())
    result.tilesCount = jTileSet["tilecount"].getNum().int

    result.firstGid = firstgid

    echo "TileSet ", result.name, " loaded!"

proc loadTiled*(tm: TileMap, path: string)=
    let jtm = parseFile(path)
    pushParentResource(path)
    try:
        if "orientation" in jtm:
            tm.orientation = parseEnum[TileMapOrientation](jtm["orientation"].getStr())
            if tm.orientation == TileMapOrientation.staggered:
                tm.isStaggerAxisX = jtm["staggeraxis"].getStr() == "x"
                tm.isStaggerIndexOdd = jtm["staggerindex"].getStr() == "odd"

        if "width" in jtm and "height" in jtm:
            tm.mapSize = newSize(jtm["width"].getFNum(), jtm["height"].getFNum())

        if "tileheight" in jtm and "tilewidth" in jtm:
            let tWidth = jtm["tilewidth"].getNum().float
            let tHeigth = jtm["tileheight"].getNum().float
            tm.tileSize = newVector3(tWidth, tHeigth)

        if "tilesets" in jtm:
            tm.tileSets = @[]

            for jts in jtm["tilesets"]:
                let ts = loadTileSet(jts)
                if not ts.isNil:
                    tm.tileSets.add(ts)

        if "layers" in jtm:
            tm.layers = @[]
            for jl in jtm["layers"]:
                let layerType = jl["type"].getStr()
                let layerCreator = tiledLayerCreators.getOrDefault(layerType)

                if layerCreator.isNil:
                    warn "TileMap loadTiled: ", layerType, " doesn't supported!"
                    continue

                var layer = layerCreator(layerType, jl)
                layer.name = jl["name"].getStr()
                layer.enabled = jl["visible"].getBVal()
                layer.alpha = jl["opacity"].getFNum()

                layer.size = newSize(jl["width"].getFNum(), jl["height"].getFNum())
                layer.position = newVector3()
                if "offsetx" in jl:
                    layer.position.x = jl["offsetx"].getFNum()
                if "offsety" in jl:
                    layer.position.y = jl["offsety"].getFNum()

                tm.layers.add(layer)
    except:
        echo getCurrentException().getStackTrace()
        raise
    finally:
        popParentResource()