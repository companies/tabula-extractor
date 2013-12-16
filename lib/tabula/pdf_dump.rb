require_relative './entities.rb'

require 'java'
java_import org.apache.pdfbox.pdfparser.PDFParser
java_import org.apache.pdfbox.util.TextPosition
java_import org.apache.pdfbox.pdmodel.PDDocument
java_import org.apache.pdfbox.util.PDFTextStripper
java_import org.apache.pdfbox.pdmodel.encryption.StandardDecryptionMaterial

module Tabula

  module Extraction

    def Extraction.openPDF(pdf_filename, password='')
      raise Errno::ENOENT unless File.exists?(pdf_filename)
      document = PDDocument.load(pdf_filename)
      if document.isEncrypted
        sdm = StandardDecryptionMaterial.new(password)
        document.openProtection(sdm)
      end
      document
    end

    class ObjectExtractor < org.apache.pdfbox.pdfviewer.PageDrawer

      attr_accessor :characters, :debug_text, :debug_clipping_paths, :clipping_paths, :rulings
      field_accessor :pageSize, :page, :graphics

      PRINTABLE_RE = /[[:print:]]/

      def initialize(pdf_filename, pages=[1], password='', options={})
        raise Errno::ENOENT unless File.exists?(pdf_filename)
        @pdf_filename = pdf_filename
        @pdf_file = Extraction.openPDF(pdf_filename, password)
        @all_pages = @pdf_file.getDocumentCatalog.getAllPages
        @pages = pages == :all ?  (1..@all_pages.size) : pages

        super()
        self.characters = []
        @graphics = java.awt.Graphics2D
        @clipping_path = nil
        @transformed_clipping_path = nil
        self.clipping_paths = []
        self.rulings = []
      end

      def extract
        Enumerator.new do |y|
          begin
            @pages.each do |i|
              page = @all_pages.get(i-1)
              contents = page.getContents
              next if contents.nil?
              self.clear!
              self.drawPage(page)
              y.yield Tabula::Page.new(@pdf_filename,
                                       page.findCropBox.width,
                                       page.findCropBox.height,
                                       page.getRotation.to_i,
                                       i, #one-indexed, just like `i` is.
                                       self.characters)
            end
          ensure
            @pdf_file.close
          end # begin
        end
      end

      def clear!
        self.characters.clear
        self.clipping_paths.clear
        self.rulings.clear
      end

      def ensurePageSize!
        if self.pageSize.nil? && !self.page.nil?
          mediaBox = self.page.findMediaBox
          self.pageSize = (mediaBox == nil ? nil : mediaBox.createDimension)
        end
      end

      def drawPage(page)
        self.page = page
        if !self.page.getContents.nil?
          ensurePageSize!
          self.processStream(self.page,
                             self.page.findResources,
                             self.page.getContents.getStream)
        end
      end

      def setStroke(stroke)
        @basicStroke = stroke
      end

      def getStroke
        @basicStroke
      end

      def strokePath
        # TODO FINISH IMPLEMENTING
        path = self.pathToList(self.getLinePath)
        if path[0][0] != java.awt.geom.PathIterator::SEG_MOVETO \
          || path[1..-1].any? { |p| p.first != java.awt.geom.PathIterator::SEG_LINETO }
          self.getLinePath.reset
          return
        end

        puts "path: #{path[0].inspect}"

        start_pos = java.awt.geom.Point2D::Float.new(path[0][1][0], path[0][1][1])

        path[1..-1].each do |p|
          end_pos = java.awt.geom.Point2D::Float.new(p[1][0], p[1][1])
          line = java.awt.geom.Line2D::Float.new(*([start_pos, end_pos].sort))

          ccp_bounds = self.currentClippingPath.getBounds2D
          if line.intersects(ccp_bounds)
            # convert line to rectangle for clipping it to the current clippath
            # sucks, but awt doesn't have methods for this
            tmp = self.transformPath(line.getBounds2D.createIntersection(ccp_bounds)).getBounds2D
            self.rulings << ::Tabula::Ruling.new(tmp.getY,
                                                 tmp.getX,
                                                 tmp.getWidth,
                                                 tmp.getHeight)
          end
          start_pos = end_pos
        end
      end

      def fillPath(windingRule)
        self.strokePath
      end

      def drawImage(image, at)
      end

      def transformPath(path)
        mb = page.findCropBox
        trans = nil
        if !([90, -270, -90, 270].include?(self.page.getRotation))
          trans = AffineTransform.getScaleInstance(1, -1)
          trans.translate(0, -mb.getHeight)
        else
          trans = AffineTransform.getScaleInstance(-1, 1)

          trans.rotate(self.page.getRotation * (Math::PI/180.0),
                       mb.getLowerLeftX, mb.getLowerLeftY)
        end
        trans.createTransformedShape(path)
      end

      def currentClippingPath
        cp = self.getGraphicsState.getCurrentClippingPath

        if cp == @clipping_path
          return @transformed_clipping_path
        end

        @clipping_path = cp

        @transformed_clipping_path =  self.transformPath(cp)
        return @transformed_clipping_path

      end

      def processTextPosition(text)
        c = text.getCharacter
        h = c == ' ' ? text.getWidthDirAdj.round(2) : text.getHeightDir.round(2)

        te = Tabula::TextElement.new(text.getYDirAdj.round(2) - h,
                                     text.getXDirAdj.round(2),
                                     text.getWidthDirAdj.round(2),
                                     # ugly hack follows: we need spaces to have a height, so we can
                                     # test for vertical overlap. height == width seems a safe bet.
                                     h,
                                     text.getFont,
                                     text.getFontSize.round(2),
                                     c,
                                     # workaround a possible bug in PDFBox: https://issues.apache.org/jira/browse/PDFBOX-1755
                                     text.getWidthOfSpace == 0 ? self.currentSpaceWidth : text.getWidthOfSpace)

        ccp_bounds = self.currentClippingPath.getBounds2D

        if self.debug_clipping_paths && !self.clipping_paths.include?(ccp_bounds)
          self.clipping_paths << ccp_bounds
        end

        if c =~ PRINTABLE_RE && ccp_bounds.intersects(te)
          self.characters << te
        end
      end

      protected

      # workaround a possible bug in PDFBox: https://issues.apache.org/jira/browse/PDFBOX-1755
      def currentSpaceWidth
        gs = self.getGraphicsState
        font = gs.getTextState.getFont

        fontSizeText = gs.getTextState.getFontSize
        horizontalScalingText = gs.getTextState.getHorizontalScalingPercent / 100.0

        if font.java_kind_of?(org.apache.pdfbox.pdmodel.font.PDType3Font)
          puts "TYPE3"
        end

        # idea from pdf.js
        # https://github.com/mozilla/pdf.js/blob/master/src/core/fonts.js#L4418
        spaceWidthText = spaceWidthText = [' ', '-', '1', 'i'] \
          .map { |c| font.getFontWidth(c.ord) } \
          .find { |w| w > 0 } || 1000

        ctm00 = gs.getCurrentTransformationMatrix.getValue(0, 0)

        return (spaceWidthText/1000.0) * fontSizeText * horizontalScalingText * (ctm00 == 0 ? 1 : ctm00)
      end

      def pathToList(path)
        iterator = path.getPathIterator(java.awt.geom.AffineTransform.new)
        rv = []
        while !iterator.isDone do
          coords = Java::double[6].new
          segType = iterator.currentSegment(coords)
          rv << [segType, coords]
          iterator.next
        end
        rv
      end

      def debugPath(path)
        rv = ''
        pathToList(path).each do |segType, coords|
          case segType
          when java.awt.geom.PathIterator::SEG_MOVETO
            rv += "MOVE: #{coords[0]} #{coords[1]}\n"
          when java.awt.geom.PathIterator::SEG_LINETO
            rv += "LINE: #{coords[0]} #{coords[1]}\n"
          when java.awt.geom.PathIterator::SEG_CLOSE
            rv += "CLOSE\n\n"
          end
        end
        rv
      end
    end


    class PagesInfoExtractor
      def initialize(pdf_filename, password='')
        @pdf_filename = pdf_filename
        @pdf_file = Extraction.openPDF(pdf_filename, password)
        @all_pages = @pdf_file.getDocumentCatalog.getAllPages
      end

      def pages
        Enumerator.new do |y|
          begin
            @all_pages.each_with_index do |page, i|
              contents = page.getContents

              y.yield Tabula::Page.new(@pdf_filename,
                                       page.findCropBox.width,
                                       page.findCropBox.height,
                                       page.getRotation.to_i,
                                       i+1) #remember, these are one-indexed
            end
          ensure
            @pdf_file.close
          end
        end
      end
    end
  end
end
