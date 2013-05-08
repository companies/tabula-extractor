require 'observer'

require_relative './entities.rb'

require 'java'
require File.join(File.dirname(__FILE__), '../../target/pdfbox-app-1.8.0.jar')
java_import org.apache.pdfbox.pdfparser.PDFParser
java_import org.apache.pdfbox.pdmodel.PDDocument
java_import org.apache.pdfbox.util.PDFTextStripper
java_import org.apache.pdfbox.pdfviewer.PageDrawer

module Tabula
  module Extraction
    class TextExtractor < org.apache.pdfbox.util.PDFTextStripper

      attr_accessor :characters, :fonts

      PRINTABLE_RE = /[[:print:]]/

      def initialize
        super
        self.fonts = {}
        self.characters = []
        self.setSortByPosition(true)
      end

      def clear!
        self.characters = []; self.fonts = {}
      end


      def processTextPosition(text)
        #    return if text.getCharacter == ' '

        # text_font = text.getFont
        # text_size = text.getFontSize
        # font_plus_size = self.fonts.select { |k, v| v == text_font }.first.first + "-" + text_size.to_i.to_s

        # $fonts[$current_page].merge!({
        #   font_plus_size => { :family => text_font.getBaseFont, :size => text_size }
        # })

        #    $page_contents[$current_page] += "  <text top=\"%.2f\" left=\"%.2f\" width=\"%.2f\" height=\"%.2f\" font=\"#{font_plus_size}\" dir=\"#{text.getDir}\">#{text.getCharacter}</text>\n" % [text.getYDirAdj - text.getHeightDir, text.getXDirAdj, text.getWidthDirAdj, text.getHeightDir]

        c = text.getCharacter
        # probably not the fastest way of detecting printable chars
        self.characters << text  if c =~ PRINTABLE_RE
      end
    end


    class CharacterExtractor
      include Observable

      def initialize(pdf_filename, pages=[])
        raise Errno::ENOENT unless File.exists?(pdf_filename)
        @pdf_file = PDDocument.loadNonSeq(java.io.File.new(pdf_filename), nil)
        @all_pages = @pdf_file.getDocumentCatalog.getAllPages
        @pages = pages
        @extractor = TextExtractor.new
      end

      def extract
        Enumerator.new do |y|
          @all_pages.each_with_index do |page, i|
            next if !@pages.empty? and !@pages.index(i+1).nil
            contents = page.getContents
            next if contents.nil?

            @extractor.clear!
            @extractor.processStream(page, page.findResources, contents.getStream)

            y << Tabula::Page.new(page.findCropBox.width,
                                  page.findCropBox.height,
                                  page.getRotation.to_i,
                                  i+1,
                                  @extractor.characters.map { |char| 
                                    Tabula::TextElement.new(char.getYDirAdj,
                                                            char.getXDirAdj,
                                                            char.getWidthDirAdj,
                                                            char.getHeightDir,
                                                            nil,
                                                            char.getFontSize,
                                                            char.getCharacter)
                                  })
          end
        end
      end
    end
  end
end



