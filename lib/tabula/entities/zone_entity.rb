java_import java.awt.geom.Point2D

module Tabula

  class ZoneEntity < java.awt.geom.Rectangle2D::Float

    attr_accessor :texts

    def initialize(top, left, width, height)
      super()
      if left && top && width && height
        self.java_send :setRect, [Java::float, Java::float, Java::float, Java::float,], left, top, width, height
      end
      self.texts = []
    end

    def merge!(other)
      self.top    = [self.top, other.top].min
      self.left   = [self.left, other.left].min
      self.width  = [self.right, other.right].max - left
      self.height = [self.bottom, other.bottom].max - top

      self.java_send :setRect, [Java::float, Java::float, Java::float, Java::float,], self.left, self.top, self.width, self.height
    end

    ##
    # default sorting order for ZoneEntity objects
    # is lexicographical (left to right, top to bottom)
    def <=>(other)
      return  1 if self.left > other.left
      return -1 if self.left < other.left
      return  0 if self.vertically_overlaps?(other)
      return  1 if self.top  > other.top
      return -1 if self.top  < other.top
      return  0
    end

    def to_json(options={})
      self.to_h.to_json
    end

    def inspect
      "#<#{self.class} dims: #{self.dims(:top, :left, :width, :height)}>"
    end

    def tlbr
      [top, left, bottom, right]
    end

    def points
      [ Point2D::Float.new(left, top),
        Point2D::Float.new(right, top),
        Point2D::Float.new(right, bottom),
        Point2D::Float.new(left, bottom) ]
    end
  end
end
