import QtQuick

// A closed book, drawn rather than borrowed from a font: no Nerd Font glyph
// reads cleanly as "reference grimoire" at bar size, and a colour emoji cannot
// follow the active theme.
//
// Drawn at 16-20px in the bar, so every feature is sized against the stroke
// width. Small details are filled, not stroked — a hollow shape needs a radius
// of roughly 2.5x the line width or it closes up solid at bar size.
Canvas {
  id: root

  property color strokeColor: "#cacccc"
  property color backgroundColor: "#101315"

  implicitWidth: 20
  implicitHeight: 20

  onStrokeColorChanged: requestPaint()
  onBackgroundColorChanged: requestPaint()

  onPaint: {
    var ctx = getContext("2d")
    var s = Math.min(width, height)
    ctx.reset()
    ctx.clearRect(0, 0, width, height)

    ctx.save()
    ctx.translate((width - s) / 2, (height - s) / 2)

    var lw = Math.max(1, s * 0.075)
    ctx.lineWidth = lw
    ctx.strokeStyle = root.strokeColor
    ctx.fillStyle = root.strokeColor
    ctx.lineJoin = "round"
    ctx.lineCap = "round"

    // Book covers: a rounded rectangle, inset so the stroke stays inside the
    // canvas at every size. Kept wide — a narrow book leaves too little page
    // for the topology and everything collides at bar size.
    var x0 = s * 0.14
    var x1 = s * 0.88
    var y0 = s * 0.13
    var y1 = s * 0.87
    var r = s * 0.06

    ctx.beginPath()
    ctx.moveTo(x0 + r, y0)
    ctx.lineTo(x1 - r, y0)
    ctx.quadraticCurveTo(x1, y0, x1, y0 + r)
    ctx.lineTo(x1, y1 - r)
    ctx.quadraticCurveTo(x1, y1, x1 - r, y1)
    ctx.lineTo(x0 + r, y1)
    ctx.quadraticCurveTo(x0, y1, x0, y1 - r)
    ctx.lineTo(x0, y0 + r)
    ctx.quadraticCurveTo(x0, y0, x0 + r, y0)
    ctx.closePath()
    ctx.stroke()

    // Spine: a second vertical rule just inside the left cover.
    var spineX = s * 0.28
    ctx.beginPath()
    ctx.moveTo(spineX, y0 + lw * 0.5)
    ctx.lineTo(spineX, y1 - lw * 0.5)
    ctx.stroke()

    // Three network nodes on the page, arranged as a small topology. These are
    // FILLED dots: at 16px a stroked ring of this radius renders solid anyway,
    // so filling is both honest and legible.
    var cx = s * 0.60
    var nodeR = Math.max(1.0, s * 0.065)

    var spreadX = s * 0.17
    var nodes = [
      { x: cx,           y: s * 0.33 },   // top
      { x: cx - spreadX, y: s * 0.66 },   // bottom-left
      { x: cx + spreadX, y: s * 0.66 }    // bottom-right
    ]

    // The connecting links are drawn only when there is room for them. Below
    // roughly 24px the link strokes plus the node casings fill the triangle
    // solid, turning a topology into an indistinct blob — three separated dots
    // still read as "nodes", a filled triangle reads as nothing.
    if (s >= 24) {
      ctx.save()
      ctx.lineWidth = Math.max(0.8, lw * 0.7)
      ctx.beginPath()
      ctx.moveTo(nodes[0].x, nodes[0].y)
      ctx.lineTo(nodes[1].x, nodes[1].y)
      ctx.moveTo(nodes[0].x, nodes[0].y)
      ctx.lineTo(nodes[2].x, nodes[2].y)
      ctx.moveTo(nodes[1].x, nodes[1].y)
      ctx.lineTo(nodes[2].x, nodes[2].y)
      ctx.stroke()
      ctx.restore()
    }

    for (var i = 0; i < nodes.length; i++) {
      // Background-coloured casing so a node reads as a distinct disc where a
      // link passes beneath it. Only needed when links are actually drawn.
      if (s >= 24) {
        ctx.beginPath()
        ctx.arc(nodes[i].x, nodes[i].y, nodeR + lw * 0.4, 0, Math.PI * 2)
        ctx.fillStyle = root.backgroundColor
        ctx.fill()
      }

      ctx.beginPath()
      ctx.arc(nodes[i].x, nodes[i].y, nodeR, 0, Math.PI * 2)
      ctx.fillStyle = root.strokeColor
      ctx.fill()
    }

    ctx.restore()
  }
}
