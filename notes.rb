require_relative 'settings'

require 'ostruct'
require 'progressbar'
require 'ontologies_linked_data'
require 'date'

require_relative 'helpers/rest_helper'

only_these_ontologies = []

def create_reply(note, parent = nil)
  user = RestHelper.user(note[:author])
  
  reply = LinkedData::Models::Notes::Reply.new
  reply.id = RDF::IRI.new("#{LinkedData::Models::Note.id_prefix.to_s}/#{note[:id].sub('Note_', '')}")
  reply.body = note[:body]
  reply.parent = parent if parent
  reply.creator = LinkedData::Models::User.find(user.username).first
  reply.created = DateTime.parse(Time.at(note[:created] / 1000).to_s)
  reply.save rescue binding.pry

  if note[:associated]
    child_notes = note[:associated].first[:noteBean]
    child_notes = child_notes.is_a?(Array) ? child_notes : [child_notes]
    child_notes.each do |child_note|
      create_reply(child_note, reply)
    end
  end

  reply
end

def convert_proposal(note, new_note)
  return unless note.type
  
  proposal = LinkedData::Models::Notes::Proposal.new

  case note.type
  when "ProposalForCreateEntity"
    values = note.values.first[:ProposalForCreateEntity]
    reasonForChange = values[:reasonForChange]
    contactInfo = values[:contactInfo]
    proposal_type = LinkedData::Models::Notes::ProposalType.find("ProposalNewClass").first

    id = values[:id].eql?("") ? nil : values[:id]
    proposal.classId = id unless id.nil?
    proposal.label = values[:preferredName]
    synonym = values[:synonyms].select {|s| !s.nil? && !s.eql?("")}
    synonym.map! {|s| s[:string].to_s rescue nil}.compact!
    proposal.synonym = synonym unless synonym.empty?
    proposal.definition = [values[:definition]]
    proposal.parent = values[:parent].first[:string] if values[:parent].is_a?(Hash)
  when "ProposalForChangeHierarchy"
    values = note.values.first[:ProposalForChangeHierarchy]
    reasonForChange = values[:reasonForChange]
    contactInfo = values[:contactInfo]
    proposal_type = LinkedData::Models::Notes::ProposalType.find("ProposalChangeHierarchy").first
    
    proposal.newTarget = values[:relationshipTarget].first[:string]
    proposal.oldTarget = values[:oldRelationshipTarget].first[:string]
    proposal.newRelationshipType = [values[:relationshipType]]
  else
    binding.pry
  end
  
  proposal.type = proposal_type
  proposal.reasonForChange = reasonForChange
  proposal.contactInfo = contactInfo
  proposal.save rescue binding.pry
  new_note.proposal = proposal

  nil
end

@errors = []
def convert_note(note)
  user = RestHelper.user(note.author)
  ont = LinkedData::Models::Ontology.find(RestHelper.safe_acronym(RestHelper.latest_ontology(note.ontologyId).abbreviation)).first
  return if ont.nil?
  nn = LinkedData::Models::Note.new
  nn.id = RDF::IRI.new("#{LinkedData::Models::Note.id_prefix.to_s}#{note.id.sub('Note_', '')}")
  nn.creator = LinkedData::Models::User.find(user.username).first
  nn.created = DateTime.parse(Time.at((note.created || (Time.now.to_i * 1000)) / 1000).to_s)
  nn.body = note.body.strip if note.body
  nn.subject = note.subject.strip if note.subject
  nn.relatedOntology = [ont]
  nn.archived = note.archived

  # Add class to note
  if note.appliesToList.first && note.appliesToList.first[:appliesTo][:type].eql?("Class")
    classId = note.appliesToList.first[:appliesTo][:id]
    latest_ont = RestHelper.latest_ontology(note.ontologyId)
    old_cls = RestHelper.concept(note.createdInOntologyVersion, classId) rescue nil
    clean_class_id = old_cls.nil? ? classId : old_cls.id
    cls = RestHelper.concept(latest_ont.id, clean_class_id) rescue nil
    cls = RestHelper.concept(latest_ont.id, classId) rescue nil unless cls
    if cls
      ont.bring(:submissions)
      submission = ont.latest_submission unless ont.submissions.empty?
      relatedClass = LinkedData::Models::Class.find(RDF::IRI.new(cls.fullId)).in(submission).first rescue nil
      nn.relatedClass = [relatedClass] unless relatedClass.nil?
    end
    
    @errors << "Could not find #{classId} for #{nn.id.to_s}" if cls.nil? && relatedClass.nil?
  end

  # Needs all versions available
  # nn.createdInSubmission = note.createdInOntologyVersion
  
  if note.type && !note.type.eql?("Comment")
    convert_proposal(note, nn)
  end
  
  # Handle children
  children = []
  if note.associated
    child_notes = note.associated.first[:noteBean] rescue binding.pry
    child_notes = child_notes.is_a?(Array) ? child_notes : [child_notes]
    child_notes.each do |child_note|
      children << create_reply(child_note)
    end
    nn.reply = children
  end

  nn.save rescue binding.pry
  nn
end

# Delete existing
if only_these_ontologies.empty?
  puts "Deleting #{LinkedData::Models::Note.all.length} notes and their replies"
  LinkedData::Models::Note.all.each {|n| n.delete}
  LinkedData::Models::Notes::Reply.all.each {|r| r.delete}
end

ontologies = RestHelper.ontologies
puts "Number of ontologies to migrate: #{ontologies.length}"
pbar = ProgressBar.new("Migrating", ontologies.length*2)
ontologies.each_with_index do |ont, ind|
  next if !only_these_ontologies.empty? && !only_these_ontologies.include?(ont.abbreviation)
  ont.bring(:notes).notes.each {|n| n.delete} if !only_these_ontologies.empty?

  begin
    notes = RestHelper.ontology_notes(ont.ontologyId)
  rescue OpenURI::HTTPError
    retry
  end
  pbar.inc
  notes.each_with_index do |note, index|
    pbar.inc if index == notes.length / 2
    new_note = convert_note(note)
  end
  pbar.inc
end

puts "Errors:", @errors.join("\n")
puts "\n\nCreated #{LinkedData::Models::Note.all.length} notes and #{LinkedData::Models::Notes::Reply.all.length} replies"
